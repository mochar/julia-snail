;;; julia-snail.el --- Julia Snail -*- lexical-binding: t -*-

;; URL: https://github.com/gcv/julia-snail
;; Package-Requires: ((emacs "26.2") (dash "2.16.0") (julia-mode "0.3") (s "1.12.0") (spinner "1.7.3"))
;; Version: 1.3.3
;; Created: 2019-10-27

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; A heavily modified fork of gcv/julia-snail

;; This package provides an interactive development environment for Julia
;; (https://julialang.org/), similar to SLIME for Common Lisp and CIDER for
;; Clojure. Refer to the README.md file for documentation.

;;; Code:


;;;; Requires

(require 'cl-lib)
(require 'dash)
(require 'easymenu)
(require 'json)
(require 'ov)
(require 'pulse)
(require 'rx)
(require 's)
(require 'seq)
(require 'spinner)
(require 'subr-x)
(require 'thingatpt)
(require 'xref)
(require 'ansi-color)

;; XXX: One of vterm, eat, or ghostel must be manually installed before Snail starts.
;; Picking one or the other involves tradeoffs best left to the user, and
;; therefore neither is added to the Package-Requires header. Briefly, vterm
;; supports older versions of Emacs (down to 26) but has more complicated module
;; compilation needs. Eat is a simpler dependency, but requires Emacs 28. The
;; two emulate terminals differently, and so one may be preferable to the other
;; for other reasons.
(when (not (or (locate-library "vterm")
               (locate-library "eat")
               (locate-library "ghostel")))
  (user-error "Neither vterm, eat, nor ghostel dependencies detected; please install one"))

(when (locate-library "vterm")
  (require 'vterm))
(declare-function vterm-end-of-line "vterm.el")
(declare-function vterm-mode "vterm.el")
(declare-function vterm-send-key "vterm.el")
(declare-function vterm-send-return "vterm.el")
(declare-function vterm-send-string "vterm.el")
(defvar vterm-shell)

(when (locate-library "eat")
  (require 'eat))
(declare-function eat-term-send-string "eat.el")
(declare-function eat-self-input "eat.el")
(defvar eat-terminal)

(when (locate-library "ghostel")
  (require 'ghostel))
(declare-function ghostel "ghostel.el")
(declare-function ghostel-send-string "ghostel.el")
(declare-function ghostel-send-key "ghostel.el")
(declare-function ghostel-readonly-end-of-line "ghostel.el")
(defvar ghostel-shell)
(defvar ghostel-buffer-name)


;;;; Customizations

(defgroup julia-snail nil
  "Customization options for Julia Snail mode."
  :group 'external)

(defcustom julia-snail-executable "julia"
  "Julia executable to run as a Snail server."
  :tag "Julia executable"
  :group 'julia-snail
  :safe 'stringp
  :type 'string)
(make-variable-buffer-local 'julia-snail-executable)

(defcustom julia-snail-extra-args nil
  "Extra arguments to pass to the Julia binary, e.g. '--sysimage /path/to/image'."
  :tag "Extra arguments (string or list of strings)"
  :group 'julia-snail
  :safe (lambda (obj) (or (null obj) (stringp obj) (listp obj)))
  :type '(choice (const :tag "None" nil)
                 (string :tag "Single string")
                 (repeat :tag "List of strings" string)))
(make-variable-buffer-local 'julia-snail-extra-args)

(defcustom julia-snail-remote-port nil
  "Default Snail server port when using a remote REPL. Do not set UNLESS using a remote REPL!"
  :tag "Snail server port (remote); do not set unless using remote REPL"
  :group 'julia-snail
  :safe (lambda (obj) (or (null obj) (integerp obj)))
  :type '(choice (const :tag "Same as local" nil)
                 (integer)))
(make-variable-buffer-local 'julia-snail-remote-port)

(defcustom julia-snail-repl-buffer "*julia*"
  "Default buffer to use for Julia REPL interaction."
  :tag "Julia REPL buffer"
  :group 'julia-snail
  :safe 'stringp
  :type 'string)
(make-variable-buffer-local 'julia-snail-repl-buffer)

(defcustom julia-snail-terminal-type
  ;; default to :vterm for historical compatibility
  (cond
   ((locate-library "vterm") :vterm)
   ((locate-library "eat") :eat)
   ((locate-library "ghostel") :ghostel)
   (t :vterm))
  "Which Emacs terminal emulator to use for the Julia REPL."
  :tag "Terminal type"
  :group 'julia-snail
  :options '(:eat :vterm :ghostel)
  :safe (lambda (v) (memq v '(:eat :vterm :ghostel)))
  :type '(choice (const :tag "Eat" :eat)
                 (const :tag "vterm" :vterm)
                 (const :tag "ghostel" :ghostel)))
;;(make-variable-buffer-local 'julia-snail-terminal-type) ; XXX: Let's not make this a buffer-local switch. Too messy.

(defcustom julia-snail-show-error-window t
  "When t: show compilation errors in separate window. When nil: display errors in the minibuffer."
  :tag "Show compilation errors in separate window"
  :group 'julia-snail
  :type 'boolean)

(defcustom julia-snail-async-timeout 20000
  "When performing asynchronous Snail operations, wait this many milliseconds before timing out."
  :tag "Timeout for asynchronous Snail operations"
  :group 'julia-snail
  :safe 'integerp
  :type 'integer)

(defcustom julia-snail-multimedia-enable nil
  "When t: enable Emacs integration with the Julia multimedia system."
  :tag "Enable Julia multimedia integration"
  :group 'julia-snail
  :safe 'booleanp
  :type 'boolean)
(make-variable-buffer-local 'julia-snail-multimedia-enable)

(defcustom julia-snail-multimedia-buffer-autoswitch nil
  "If true, when an image is displayed inside Emacs, the
multimedia buffer gets the focus (e.g., for zooming and panning).
If nil, the image window is displayed but focus remains on the
REPL buffer."
  :tag "Automatically switch to multimedia (plot) content buffer"
  :group 'julia-snail
  :type 'boolean)

(defcustom julia-snail-multimedia-buffer-style :single-reuse
  "Controls multimedia buffer behavior. When
:single-reuse (default), reuse the same buffer to show every
image; this erases previous images. When :single-new, open a new
buffer for every image. When :multi, insert images one after
another."
  :tag "Control multimedia buffer behavior"
  :group 'julia-snail
  :options '(:single-reuse :single-new :multi)
  :safe (lambda (v) (memq v '(:single-reuse :single-new :multi)))
  :type '(choice (const :tag "Reuse buffer and replace image" :single-reuse)
                 (const :tag "New buffer for each image" :single-new)
                 (const :tag "Append images to buffer" :multi)))
(make-variable-buffer-local 'julia-snail-multimedia-buffer-style)

(defcustom julia-snail-completions-doc-enable t
  "If company-mode is installed, this flag determines if its documentation integration should be enabled."
  :tag "Control company-mode documentation integration"
  :group 'julia-snail
  :safe 'booleanp
  :type 'boolean)

(defcustom julia-snail-use-emoji-mode-lighter t
  "If true, try to use a snail emoji in the modeline lighter instead of text."
  :tag "Control use of emoji in modeline lighter"
  :group 'julia-snail
  :safe 'booleanp
  :type 'boolean)

(defcustom julia-snail-repl-display-eval-results nil
  "If true, show the results of evaluating code sent from Emacs in the Julia REPL."
  :tag "Control display of eval results in Julia REPL"
  :group 'julia-snail
  :safe 'booleanp
  :type 'boolean)

(defcustom julia-snail-copy-eval-results-to-kill-ring nil
  "If true, copy inline evaluation results to the kill ring automatically."
  :tag "Copy inline evaluation results to kill ring automatically"
  :group 'julia-snail
  :safe 'booleanp
  :type 'boolean)

(defcustom julia-snail-srcbuf-overlays t
  "Display evaluation results as overlays in the source buffers.
If this variable is non-nil, evaluation results are displayed as
overlays at the end of the line if possible."
  :group 'julia-snail
  :type 'boolean)

(defcustom julia-snail-srcbuf-overlay-prefix "=> "
  "Evaluation result overlays will be prefixed with this string."
  :group 'julia-snail
  :type 'string)

(defcustom julia-snail-imenu-style :module-tree
  "Control how imenu should be structured.
nil means disable Snail-specific imenu integration (fall back on julia-mode implementation).
:flat means entries are prefixed by Julia module, e.g. 'MyModule.myfunction1()'
:module-tree means entries use Julia modules to make subtrees, so 'myfunction1()' becomes an entry under 'MyModule'. This is useful with something like the imenu-list package."
  :tag "Control imenu integration"
  :group 'julia-snail
  :safe (lambda (v) (memq v '(:flat :module-tree nil)))
  :set (lambda (symbol value)
         (set-default symbol value)
         ;; invalidate the cache in all buffers
         (cl-loop for buf in (buffer-list) do
                  (with-current-buffer buf
                    (defvar julia-snail--imenu-cache)
                    (setq julia-snail--imenu-cache nil))))
  :type '(choice (const :tag "Flat" :flat)
                 (const :tag "Module-based tree structure" :module-tree)
                 (const :tag "Use julia-mode" nil)))

(defcustom julia-snail-extensions (list)
  "A list of enabled Snail extensions."
  :tag "Enabled Snail extensions"
  :group 'julia-snail
  :safe (lambda (obj)
          (and (listp obj)
               (seq-every-p #'symbolp obj)))
  :type '(repeat :tag "Extension" symbol))
(make-variable-buffer-local 'julia-snail-extensions)


;;;; Constants

(defconst julia-snail--julia-files
  ;; A slightly specialized directory walker to collect the correct file and
  ;; directory list:
  (cl-labels ((list-extension-files (&optional (path "src/extensions"))
                (let* ((result nil)
                       (entries (cl-remove-if
                                 (lambda (entry)
                                   (or (string-match-p "^\\." (file-name-nondirectory entry))
                                       (and (file-regular-p (concat (file-name-as-directory path) entry))
                                            (not (or (string-equal "jl" (downcase (or (file-name-extension entry) "")))
                                                     (string-equal "toml" (downcase (or (file-name-extension entry) ""))))))))
                                 (directory-files path)))
                       (qualified-entries (if (string-equal "." path)
                                              entries
                                            (mapcar (lambda (entry)
                                                      (concat (file-name-as-directory path) entry))
                                                    entries))))
                  (cl-loop for entry in qualified-entries do
                           (if (file-regular-p entry)
                               (setq result (cons entry result))
                             (when (file-directory-p entry)
                               (setq result (cons entry result))
                               (setq result (append result (list-extension-files entry))))))
                  result)))
    ;; actually put together the list
    (append
     (list "src/JuliaSnail.jl" "Project.toml" "src/extensions")
     (let ((default-directory (file-name-directory (or load-file-name (buffer-file-name)))))
       (list-extension-files)))))

(defconst julia-snail--julia-files-local
  (mapcar (lambda (f)
            (concat (file-name-directory (or load-file-name (buffer-file-name))) f))
          julia-snail--julia-files))

(defconst julia-snail--server-file
  (-find (lambda (f)
           (string-equal "JuliaSnail.jl" (file-name-nondirectory f)))
         julia-snail--julia-files-local))


;;;; Data structures

(cl-defstruct julia-snail-request-display
  type
  value
  meta
  counter
  result-p)

(cl-defstruct julia-snail-request-data
  "Stores result and stream (stdout+stderr) of a request."
  stream-buf
  result
  displays
  error-message
  error-stack
  finalizer)

(cl-defstruct julia-snail-request
  "Snail protocol request tracking data structure."
  id
  repl-buf
  marker
  (callback-success (lambda (&rest _) (message "Snail command succeeded")))
  (callback-failure (lambda (&rest _) (message "Snail command failed")))
  callback-stream
  callback-display
  (display-error-buffer-on-failure? t)
  babel-props
  data
  srcbuf-ov
  tmpfile
  tmpfile-local-remote)

(cl-defstruct julia-snail--imenu-cache-entry
  timestamp
  tick
  value)


;;;; Variables

(defvar julia-snail-debug nil
  "When t, show more runtime information.")

(defvar-local julia-snail--process nil)

(defvar-local julia-snail-port nil
  "Snail server port for Emacs to connect to.  If nil will be set automatically using `julia-snail-port-counter'.")

(defvar julia-snail-port-counter 10011
  "Counter for dynamically allocating Snail ports.")

;; TODO: Maybe this should hash by proc+reqid rather than just reqid?
(defvar julia-snail--requests
  (make-hash-table :test #'equal))

(defvar julia-snail--proc-responses
  (make-hash-table :test #'equal))

(defvar julia-snail--cache-proc-implicit-file-module
  (make-hash-table :test #'equal))

(defvar julia-snail--cache-proc-basedir
  (make-hash-table :test #'equal))

(defvar julia-snail--imenu-fallback-index-function nil)

(defvar-local julia-snail--repl-go-back-target nil)

(defvar-local julia-snail--last-eval-result nil)

(defvar-local julia-snail--imenu-cache nil)

(defvar julia-snail--compilation-regexp-alist
  '(;; matches "while loading /tmp/Foo.jl, in expression starting on line 2"
    (julia-load-error . ("while loading \\([^ ><()\t\n,'\";:]+\\), in expression starting on line \\([0-9]+\\)" 1 2))
    ;; matches "around /tmp/Foo.jl:2", also starting with "at" or "Revise"
    (julia-loc . ("\\(around\\|at\\|Revise\\) \\([^ ><()\t\n,'\";:]+\\):\\([0-9]+\\)" 2 3))
    ;; matches "omitting file /tmp/Foo.jl due to parsing error near line 2", from Revise.parse_source!
    (julia-warn-revise . ("omitting file \\([^ ><()\t\n,'\";:]+\\) due to parsing error near line \\([0-9]+\\)" 1 2))
    ;; matches "@ <something> /tmp/Foo.jl:2"
    ;; skips "Closest candidates are" matches 
    (julia-stacktrace .
                      ("^[ \t]*\\[[0-9]+\\][^\n]*\n[ \t]*@[ \t]+\\(?:[a-zA-Z0-9_.#]+[ \t]+\\)?\\(\\([^ \t\n:]+\\):\\([0-9]+\\)\\)"
                       2 3 nil nil 1))
    )
  "Specifications for highlighting error locations.
Uses function `compilation-shell-minor-mode'.")


;;;; Pre-declarations

(defvar julia-snail-mode)
(defvar julia-snail-repl-mode)

;;;; Request structure functions

(defun julia-snail-request-make-display (request type value meta result-p)
  (when value
    (let* ((data (julia-snail-request-data request))
           (displays (julia-snail-request-data-displays data)))
      (make-julia-snail-request-display
       :type type
       :value value
       :meta meta
       :result-p result-p
       :counter (length displays)))))

(defun julia-snail-request-data-resolve (request-or-data)
  (cond
   ((julia-snail-request-p request-or-data)
    (julia-snail-request-data request-or-data))
   ((julia-snail-request-data-p request-or-data)
    request-or-data)))
  
(defun julia-snail-request-data-options (request-or-data &optional include-error)
  (pcase-let* ((data (julia-snail-request-data-resolve request-or-data))
               ((cl-struct julia-snail-request-data
                           displays result stream-buf error-message error-stack) data)
               (n-displays (length displays))
               (stream-empty-p (= 0 (buffer-size stream-buf))))
    (append
     (unless stream-empty-p '(stream))
     (number-sequence 0 (1- n-displays))
     (when result '(result))
     (when (and include-error (or error-message error-stack)) '(error)))))

(defun julia-snail-request-data-empty-p (request-or-data)
  (null (julia-snail-request-data-options request-or-data)))

;;;; Supporting functions

(defun julia-snail--copy-buffer-local-vars (from-buf)
  "Copy Snail-related buffer-local variables from FROM-BUF to the current buffer."
  (dolist (blv (buffer-local-variables from-buf))
    (let* ((var (car blv))
           (var-name (symbol-name var))
           (val (cdr blv)))
      (when (and (string-prefix-p "julia-snail-" var-name)
                 (not (string-suffix-p "-mode" var-name)))
        (set var val)))))

(defun julia-snail--process-buffer-name (repl-buf)
  "Return the process buffer name for REPL-BUF."
  (let ((real-buf (get-buffer repl-buf)))
    (unless real-buf
      (error "No REPL buffer found"))
    (format "%s process" (buffer-name (get-buffer real-buf)))))

(cl-defun julia-snail--message-buffer (repl-buf name message &key (markdown nil))
  "Return a buffer named NAME linked to REPL-BUF containing MESSAGE."
  (let ((real-buf (get-buffer repl-buf)))
    (unless real-buf
      (error "No REPL buffer found"))
    (let* ((msg-buf-name (format "%s %s" (buffer-name (get-buffer real-buf)) name))
           (msg-buf (get-buffer-create msg-buf-name)))
      (with-current-buffer msg-buf
        (read-only-mode -1)
        (erase-buffer)
        (insert message)
        (goto-char (point-min))
        (cond
         ((and markdown (fboundp 'markdown-mode))
          (defvar markdown-hide-markup)
          (declare-function markdown-mode "markdown-mode.el")
          (declare-function markdown-view-mode "markdown-mode.el")
          (let ((markdown-hide-markup t))
            ;; older versions of markdown-mode do not have markdown-view-mode
            (if (fboundp 'markdown-view-mode)
                (markdown-view-mode)
              (markdown-mode))))
         (t
          (ansi-color-apply-on-region (point-min) (point-max))))
        (read-only-mode 1)
        (julia-snail-message-buffer-mode 1))
      msg-buf)))

;; set error buffer to compilation mode, so that one may directly jump to the relevant files
;; adapted from julia-repl by Tamas Papp
(defun julia-snail--setup-compilation-mode (message-buffer basedir)
  "Setup compilation mode for the the current buffer in MESSAGE-BUFFER.
BASEDIR is used for resolving relative paths."
  (with-current-buffer message-buffer
    (compilation-mode)
    (setq-local compilation-error-regexp-alist-alist
                julia-snail--compilation-regexp-alist)
    (setq-local compilation-error-regexp-alist
                (mapcar #'car compilation-error-regexp-alist-alist))
    (when basedir
      (setq-local compilation-search-path (list basedir)))))

(defun julia-snail--flash-region (start end &optional timeout)
  "Highlight the region outlined by START and END for TIMEOUT period."
  (if (display-graphic-p)
      ;; this (sometimes?) does not seem to work in terminal Emacs (?!); the
      ;; overlay does not go away like it does in GUI Emacs
      (pulse-momentary-highlight-region start end 'highlight)
    ;; borrowed from SLIME:
    (let ((overlay (make-overlay start end)))
      (overlay-put overlay 'face 'highlight)
      (run-with-timer (or timeout 0.2) nil 'delete-overlay overlay))))

(defun julia-snail--construct-module-path (module)
  "Return a Julia array representing the module path of MODULE as Julia symbols.
MODULE can be:
- nil, which returns [:Main]
- an Elisp keyword, which returns [<keyword>], including the
  leading colon in the keyword
- an Elisp string, which is split by dot and converted to Julia array literal
- an Elisp list, which can contain either keywords or strings,
  and which is converted to a Julia array literal with the
  entries of the input list converted to Julia keywords"
  (cond ((null module)
         "[:Main]")
        ((keywordp module)
         (format "[%s]" module))
        ((stringp module)
         (julia-snail--construct-module-path (split-string module "\\.")))
        ((listp module)
         (format
          "[%s]"
          (s-join " " (-map (lambda (s)
                              (if (keywordp s)
                                  (format "%s" s)
                                (format ":%s" s)))
                            module))))
        (t (error "Malformed module specification"))))

(defmacro julia-snail--with-syntax-table (&rest body)
  "Evaluate BODY with a Snail-specific syntax table."
  (declare (indent defun))
  `(let ((stab (copy-syntax-table)))
     (with-syntax-table stab
       (modify-syntax-entry ?. "_")
       (modify-syntax-entry ?@ "_")
       (modify-syntax-entry ?! "_")
       (modify-syntax-entry ?= " ")
       (modify-syntax-entry ?$ " ")
       ,@body)))

(defun julia-snail--bslash-before-p (pos)
  (when-let (c (char-before pos))
    (char-equal c ?\\)))

(defun julia-snail--identifier-at-point ()
  "Return identifier at point using Snail-specific syntax table."
  (julia-snail--with-syntax-table
    (let ((identifier (thing-at-point 'symbol t))
          (start (car (bounds-of-thing-at-point 'symbol))))
      (if (julia-snail--bslash-before-p start)
          (concat "\\" identifier)
        identifier))))

(defun julia-snail--identifier-at-point-bounds ()
  "Return the bounds of the identifier at point using Snail-specific syntax table."
  (julia-snail--with-syntax-table
    (let ((bounds (bounds-of-thing-at-point 'symbol)))
      (if (julia-snail--bslash-before-p (car bounds))
          `(,(- (car bounds) 1) . ,(cdr bounds))
        bounds))))

(defmacro julia-snail--wait-while (condition increment maximum)
  "Synchronously wait as long as CONDITION evaluates to true.
INCREMENT: polling frequency, ms.
MAXIMUM: max timeout, ms.
Returns nil if the poll timed out, t otherwise."
  (let ((sleep-total (gensym))
        (incr (gensym))
        (max (gensym)))
    `(let ((,sleep-total 0.0)
           ;; convert arguments from milliseconds to seconds for sit-for
           (,incr (/ ,increment 1000.0))
           (,max (/ ,maximum 1000.0)))
       (while (and (< ,sleep-total ,max) ,condition)
         ;; XXX: This MUST be sleep-for, not sit-for. sit-for is interrupted by
         ;; input, which breaks the loop on input, which will inadvertently kill
         ;; the wait.
         (redisplay)
         (sleep-for ,incr)
         (setf ,sleep-total (+ ,sleep-total ,incr)))
       ;; return value: t if wait returned early, nil if it timed out
       (< ,sleep-total ,max))))

(defun julia-snail--capture-basedir (buf)
  (julia-snail--send-to-server
    :Main
    "normpath(joinpath(VERSION <= v\"0.7-\" ? JULIA_HOME : Sys.BINDIR, Base.DATAROOTDIR, \"julia\", \"base\"))"
    :repl-buf buf
    :async nil))

(defun julia-snail-test-file-path (file)
  "Test suite accessory: Return path to FILE in the test area."
  ;; XXX: Obnoxious Elisp path construction.
  (let ((location (file-name-directory (locate-library "julia-snail"))))
    (concat
     (file-name-as-directory
      (concat (if load-file-name
                  (file-name-directory load-file-name)
                (file-name-as-directory location))
              (file-name-as-directory "tests")
              (file-name-as-directory "files")))
     file)))

(defun julia-snail-test-send-buffer-file-sync ()
  "Test suite accessory: Same as julia-snail-send-buffer-file, but synchronous."
  (let ((reqid (julia-snail-send-buffer-file))) ; wait for async result to return
    (julia-snail--wait-while
     (gethash reqid julia-snail--requests) 50 10000)))

(defun julia-snail--send-helper (block-start block-end)
  (let ((text (buffer-substring-no-properties block-start block-end))
        (module (if current-prefix-arg :Main (julia-snail--module-at-point))))
    (julia-snail--flash-region block-start block-end)
    (julia-snail--send-to-server
      module
      text
      :srcbuf-ov (when (julia-snail-srcbuf-ov-p) (cons block-start block-end))
      :callback-stream
      (lambda (request type)
        (when-let* ((ov (julia-snail-request-srcbuf-ov request)))
          (julia-snail-srcbuf-ov--update ov)))
      :callback-display
      (lambda (request display)
        (when-let* ((ov (julia-snail-request-srcbuf-ov request)))
          (julia-snail-srcbuf-ov-refresh ov)))
      :callback-success
      (lambda (request result)
        (when-let ((res (and result (format "%s" result))))
          ;; Update overlay
          (when-let* ((ov (julia-snail-request-srcbuf-ov request)))
            (julia-snail-srcbuf-ov--update ov))
            
          ;; Insert results when prefix arg
          (when (and (consp current-prefix-arg) (= (car current-prefix-arg) 4))
            (let* ((parts (split-string result "\n"))
                   (str (mapconcat (lambda (part) (concat "# " part)) parts "\n")))
              (save-excursion
                (end-of-line)
                (insert "\n" str)))))
        ;; (message "Evaluated; module %s"
        ;;          (julia-snail--construct-module-path module))
        ))))

(defun julia-snail--encode-base64 (&optional buf)
  (let ((s (with-current-buffer (or buf (current-buffer))
             (encode-coding-string (buffer-string)
                                   buffer-file-coding-system))))
    (base64-encode-string s)))

(defun julia-snail--file-checksum (file)
  (with-temp-buffer
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun julia-snail--staged-runtime-private-p (staged-runtime-dir)
  (let ((modes (file-modes staged-runtime-dir)))
    (and modes
         (zerop (logand modes #o077)))))

(defun julia-snail--staged-runtime-current-p (staged-runtime-dir)
  (condition-case nil
      (and (julia-snail--staged-runtime-private-p staged-runtime-dir)
           (cl-loop for f in julia-snail--julia-files
                    for local-f in julia-snail--julia-files-local
                    for staged-f = (concat staged-runtime-dir f)
                    always
                    (cond
                     ((file-directory-p local-f)
                      (file-directory-p staged-f))
                     ((file-regular-p local-f)
                      (and (file-regular-p staged-f)
                           (string-equal (julia-snail--file-checksum local-f)
                                         (julia-snail--file-checksum staged-f))))
                     (t nil))))
    (error nil)))

(defun julia-snail--stage-julia-runtime ()
  (let* (;; checksum all relevant files as one, copy into a directory
         ;; keyed off the checksum if it doesn't already exist (basically cache
         ;; the current version of the Julia code (.jl and .toml files)
         (checksum (with-temp-buffer
                     (cl-loop for f in julia-snail--julia-files-local do
                              (when (file-regular-p f)
                                (insert-file-contents-literally f)))
                     (secure-hash 'sha256 (current-buffer))))
         (staged-runtime-dir (concat (file-name-as-directory (temporary-file-directory))
                                     (concat "julia-snail-" checksum "/"))))
    (unless (julia-snail--staged-runtime-current-p staged-runtime-dir)
      (when (file-exists-p staged-runtime-dir)
        (delete-directory staged-runtime-dir t))
      (make-directory staged-runtime-dir t)
      (set-file-modes staged-runtime-dir #o700)
      (let ((default-directory (file-name-directory (locate-library "julia-snail"))))
        (cl-loop for f in julia-snail--julia-files do
                 (if (file-directory-p f)
                     (make-directory (concat staged-runtime-dir f) t)
                    (copy-file (file-truename f) (concat staged-runtime-dir (file-name-directory f)) t)))))
    staged-runtime-dir))

(defun julia-snail--local-runtime-needs-staging-p ()
  "Return non-nil when the installed Julia runtime directory is not writable."
  (not (file-writable-p (file-name-directory julia-snail--server-file))))

(defun julia-snail--launch-command ()
  (let* ((extra-args (if (listp julia-snail-extra-args)
                         (mapconcat 'identity julia-snail-extra-args " ")
                       julia-snail-extra-args))
	 (remote-method (file-remote-p default-directory 'method))
         (remote-user (file-remote-p default-directory 'user))
         (remote-host (file-remote-p default-directory 'host))
	 (staged-runtime-dir (when (or remote-method
                                      (julia-snail--local-runtime-needs-staging-p))
                              (julia-snail--stage-julia-runtime)))
         (server-file (if staged-runtime-dir
                          (let ((staged-server-file (concat staged-runtime-dir "JuliaSnail.jl")))
                            (if remote-method
                                (file-remote-p staged-server-file 'localname)
                              staged-server-file))
                        julia-snail--server-file)))
    (cond
     ;; Local REPL
     ((null remote-method)
      ;; (format "%s -i %s -L %s" julia-snail-executable extra-args server-file)
      (let* ((src-dir (file-name-directory server-file))
             (project-dir (file-name-directory (directory-file-name src-dir)))
             (code (format
                    "pushfirst!(LOAD_PATH, %S); import JuliaSnail; popfirst!(LOAD_PATH); push!(LOAD_PATH, %S)" 
                    project-dir project-dir)))
        (format "%s -i %s -e %S" julia-snail-executable extra-args code))
      )
     ;; remote REPL
     ((or (string-equal "ssh" remote-method)
          (string-equal "sshx" remote-method)
          (string-equal "scp" remote-method)
          (string-equal "scpx" remote-method))
      (format "ssh -t -L %1$s:localhost:%2$s %3$s %4$s %5$s -L %6$s"
              julia-snail-port
              (or julia-snail-remote-port julia-snail-port)
              (concat
               (if remote-user (concat remote-user "@") "")
               remote-host)
               julia-snail-executable
               extra-args
               server-file))
     ;; container REPL
     ((string-equal "docker" remote-method)
      (format "docker exec -it %s %s %s -L %s"
	      remote-host
	      julia-snail-executable
	      extra-args
	      server-file))
     ;; unsupported method
     (t
      (user-error "Unsupported Tramp method %s" remote-method)))))

(defun julia-snail--start (source-buf)
  "Underlying command for julia-snail invocation.
Supports multiple terminal implementations."
  (let* ((launch-command (julia-snail--launch-command))
         ;; XXX: Set the error color to red to work around breakage relating to
         ;; some color themes and terminal combinations, see
         ;; https://github.com/gcv/julia-snail/issues/11
         (process-environment (append '("JULIA_ERROR_COLOR=red") process-environment))
         ;; XXX: When a remote REPL is being started, bind the terminal buffer's
         ;; default-directory to the user's home because if (1) a remote REPL is
         ;; being started, default-directory may be remote, and (2) Tramp may
         ;; notice this, mess with the path, and run ssh incorrectly.
         ;; But also ensure we can set the default-directory to the
         ;; proper value after creating the terminal buffer.
         (orig-dir default-directory)
         (default-directory (if (file-remote-p default-directory)
                                (expand-file-name "~")
                              default-directory)))
    (let ((terml-buf
           ;; first, start a REPL process in a new buffer
           (cond
            ;; vterm
            ((eq :vterm julia-snail-terminal-type)
             (let ((vterm-shell launch-command)
                   (terml-buf (generate-new-buffer julia-snail-repl-buffer)))
               (pop-to-buffer terml-buf)
               (with-current-buffer terml-buf
                 (vterm-mode))
               terml-buf))
            ;; eat
            ((eq :eat julia-snail-terminal-type)
             (let ((terml-buf (eat launch-command t))
                   (repl-buffer-name julia-snail-repl-buffer))
               (with-current-buffer terml-buf
                 (rename-buffer repl-buffer-name))
               terml-buf))
            ;; ghostel
            ((eq :ghostel julia-snail-terminal-type)
             (let* ((command-and-args (split-string-and-unquote launch-command))
                    (command (executable-find (seq-first command-and-args)))
                    (args (seq-rest command-and-args))
                    (buffer (generate-new-buffer julia-snail-repl-buffer)))
               (pop-to-buffer buffer)
               (ghostel-exec buffer command args)
               ;; Prevent ghostel's title tracking logic from messing up our
               ;; buffer name.
               (with-current-buffer buffer
                 (setq-local ghostel-buffer-name-function nil))
               buffer))
            ;; unsupported value
            (t
             (user-error "unsupported value for julia-snail-terminal-type: %s" julia-snail-terminal-type)))))
      ;; then deal with some setup on that buffer
      (with-current-buffer terml-buf
        (when source-buf
          (julia-snail--copy-buffer-local-vars source-buf)
          (setq julia-snail--repl-go-back-target source-buf)
          (cd orig-dir))
        (julia-snail-repl-mode)))))

(defun julia-snail--efn (path &optional starting-dir)
  "A variant of expand-file-name that (1) just does
expand-file-name on local files, and (2) returns the expanded
form of the remote path without any host connection string
components. Example: (julia-snail--efn \"/ssh:host:~/file.jl\")
returns \"/home/username/file.jl\"."
  (let* ((expanded (expand-file-name path starting-dir))
         (remote-local-path (file-remote-p expanded 'localname)))
    (if remote-local-path
        remote-local-path
      expanded)))

(defun julia-snail--add-to-perspective (buf)
  (when (and (featurep 'perspective) (bound-and-true-p persp-mode)) ; perspective-el support
    (declare-function persp-add-buffer "perspective.el")
    (persp-add-buffer buf))
  (when (and (featurep 'persp-mode) (bound-and-true-p persp-mode)) ; persp-mode support
    (declare-function persp-add-buffer "persp-mode.el")
    (declare-function get-current-persp "persp-mode.el")
    (persp-add-buffer buf (get-current-persp) nil)))

(defun julia-snail--spinner-print-around (fn &rest args)
  "Advice for `spinner-print` to add a leading space so the spinner looks nicer in the modeline."
  (let ((fn-res (apply fn args)))
    (if (> (length fn-res) 0)
        (concat " " fn-res)
      fn-res)))

(defun julia-snail--mode-lighter (&optional extra)
  (let ((snail-emoji (char-from-name "SNAIL")))
    (if (and julia-snail-use-emoji-mode-lighter
             snail-emoji
             (char-displayable-p snail-emoji))
        (format " %c%s" snail-emoji (if extra extra ""))
      (format " Snail%s" (if extra extra "")))))


;;;; Connection management

(defun julia-snail--clear-proc-caches (process-buf)
  "Clear connection-specific internal Snail xref, completion, and module caches."
  (when process-buf
    (remhash process-buf julia-snail--cache-proc-implicit-file-module)
    (remhash process-buf julia-snail--cache-proc-basedir)))

(defun julia-snail--repl-cleanup ()
  "REPL buffer cleanup."
  (let ((process-buf (get-buffer (julia-snail--process-buffer-name (current-buffer)))))
    (julia-snail--clear-proc-caches process-buf)
    (when process-buf
      (kill-buffer process-buf)))
  (setq julia-snail--process nil))

(defun julia-snail--repl-enable ()
  "REPL buffer minor mode initializer."
  (add-hook 'kill-buffer-hook #'julia-snail--repl-cleanup nil t)
  (let ((repl-buf (current-buffer))
        (process-buf (get-buffer-create (julia-snail--process-buffer-name (current-buffer)))))
    (julia-snail--add-to-perspective process-buf)
    (with-current-buffer process-buf
      (unless julia-snail--process
        (julia-snail--copy-buffer-local-vars repl-buf)
        ;; XXX: This is currently necessary because there does not appear to be
        ;; a way to pass arguments to an interactive Julia session. This does
        ;; not work: `julia -L JuliaSnail.jl -- $PORT`.
        ;; https://github.com/JuliaLang/julia/issues/10226 refers to this
        ;; problem and supposedly fixes it, but it does not work for me with
        ;; Julia 1.0.4.
        ;; TODO: Follow-up on https://github.com/JuliaLang/julia/issues/33752
        (message "Starting Julia process and loading Snail...")
        ;; XXX: Wait briefly in case the Julia executable failed to launch.
        (with-current-buffer repl-buf
          ;; XXX: This use of julia-snail--wait-while causes a mysterious
          ;; byte-compiler warning saying the result value of the macro is
          ;; unused. Indeed, this is intentional. Plenty of other places in the
          ;; code ignore the return value of julia-snail--wait-while, all
          ;; without causing the byte-compiler to complain.
          (with-no-warnings
            (julia-snail--wait-while
             (not (string-equal "julia>" (current-word)))
             100
             3000)))
        (unless (buffer-live-p repl-buf)
          (user-error "The REPL terminal buffer is inactive; double-check julia-snail-executable path"))
        ;; now try to send the Snail startup command
        (julia-snail--send-to-repl
         (format "JuliaSnail.start(%d%s) ; # please wait, time-to-first-plot..."
		 (or julia-snail-remote-port julia-snail-port)
		 (if (string-equal "docker" (file-remote-p (buffer-file-name julia-snail--repl-go-back-target) 'method))
		     "; addr=\"0.0.0.0\""
		   ""))
          :repl-buf repl-buf
          ;; wait a while in case dependencies need to be downloaded
          :polling-timeout (* 5 60 1000)
          :async nil)
        (let ((netstream (let ((attempt 0)
                               (max-attempts 15)
                               (stream nil))
                           (while (and (< attempt max-attempts) (null stream))
                             (cl-incf attempt)
                             (message "Snail connecting to Julia process, attempt %d/%d..." attempt max-attempts)
                             (condition-case nil
                                 (setq stream (open-network-stream "julia-process" process-buf "localhost" julia-snail-port))
                               (error (when (< attempt max-attempts)
                                        (sleep-for 0.75)))))
                           stream)))
          (if netstream
              (with-current-buffer repl-buf
                ;; NB: buffer-local variable!
                (setq julia-snail--process netstream)
                (set-process-filter julia-snail--process #'julia-snail--server-response-filter)
                ;; TODO: Implement a sanity check on the Julia environment. Not
                ;; sure how. But a failed dependency load (like CSTParser) will
                ;; leave Snail in a bad state.
                (message "Successfully connected to Snail server in Julia REPL")
                ;; Query base directory, and cache
                (puthash process-buf (julia-snail--capture-basedir repl-buf)
                         julia-snail--cache-proc-basedir))
            ;; something went wrong
            (error "Failed to connect to Snail server"))
          ;; post-connection initialization:
          (when netstream
            (when (buffer-local-value 'julia-snail-multimedia-enable repl-buf)
              (julia-snail--send-to-server
                '("JuliaSnail" "Multimedia")
                "display_on()"
                :repl-buf repl-buf
                :async nil))
            ;; activate extensions
            (cl-loop for extname in julia-snail-extensions do
                     ;; load the extension Elisp file (if necessary)
                     (julia-snail--extension-load extname)
                     ;; run extension initialization function
                     (let ((init-fn (julia-snail--extension-init extname)))
                       (message "Loading Snail extension %s..." extname)
                       (when (functionp init-fn)
                         (funcall init-fn repl-buf))))
            (when (> (length julia-snail-extensions) 0)
              (message "Finished loading Snail extensions"))
            ;; enable REPL evaluation output
            (when julia-snail-repl-display-eval-results
              (julia-snail--send-to-server
                '("JuliaSnail" "Conf")
                "set!(:repl_display_eval_results, true)"
                :repl-buf repl-buf
                :async nil))
            ;; ensure the `default-directory' is correct in case of
            ;; remote REPLs
            (julia-snail--send-to-server
              :Main
              (format "cd(%s)" (json-encode-string (julia-snail--efn default-directory)))
              :repl-buf repl-buf
              :async nil)
            ;; other initializations can go here
            ;; all done!
            (message "Snail initialization complete. Happy hacking!")
            ))))))

(defun julia-snail--repl-disable ()
  "REPL buffer minor mode cleanup."
  (julia-snail--repl-cleanup))

(defun julia-snail--enable ()
  "Source buffer minor mode initializer."
  ;; turn on extension minor modes
  (hack-dir-local-variables-non-file-buffer) ; force .dir-locals.el to load
  (cl-loop for extname in julia-snail-extensions do
           ;; load the extension Elisp file (if necessary)
           (julia-snail--extension-load extname)
           (let ((minor-mode-fn (julia-snail--extension-mode extname)))
             (when (functionp minor-mode-fn)
               (funcall minor-mode-fn 1))))
  ;; other minor mode initializations can go here
  )

(defun julia-snail--disable ()
  "Source buffer minor mode cleanup."
  ;; turn off extension minor modes
  (cl-loop for extname in julia-snail-extensions do
           (let ((minor-mode-fn (julia-snail--extension-mode extname)))
             (when (functionp minor-mode-fn)
               (funcall minor-mode-fn -1))))
  ;; other minor mode cleanup can go here
  )


;;;; Terminal emulators

(defun julia-snail--terminal-send-string (str)
  (cond
   ;; Eat
   ((eq 'eat-mode major-mode)
    (eat-term-send-string eat-terminal str)
    ;; TODO: Remove this call when https://codeberg.org/akib/emacs-eat/issues/100 is fixed.
    (when (fboundp 'eat--process-input-queue)
      (declare-function eat--process-input-queue "eat.el")
      (eat--process-input-queue (current-buffer))))
   ;; vterm
   ((eq 'vterm-mode major-mode)
    (vterm-send-string str))
   ;; ghostel
   ((eq 'ghostel-mode major-mode)
    (ghostel-send-string str))
   ;; error and debugging
   (t
    (error "function called out of context; (with-current-buffer repl-buf ...) required"))))

(defun julia-snail--terminal-send-return ()
  (cond
   ;; Eat
   ((eq 'eat-mode major-mode)
    (eat-term-send-string eat-terminal "\n")
    ;; TODO: Remove this call when https://codeberg.org/akib/emacs-eat/issues/100 is fixed.
    (when (fboundp 'eat--process-input-queue)
      (declare-function eat--process-input-queue "eat.el")
      (eat--process-input-queue (current-buffer))))
   ;; vterm
   ((eq 'vterm-mode major-mode)
    (vterm-send-return))
   ;; ghostel
   ((eq 'ghostel-mode major-mode)
    (ghostel-send-key "return"))
   ;; error and debugging
   (t
    (error "function called out of context; (with-current-buffer repl-buf ...) required"))))


;;;; REPL and Snail server interaction

(defun julia-snail--looking-back-string (str)
  "Return t if the buffer contents preceding point matches `str'. The same
as `looking-back', but for string matches instead of regular expression
matches."
  (string-equal str
                (buffer-substring-no-properties (- (point) (length str))
                                                (point))))

(cl-defun julia-snail--send-to-repl
    (str
     &key
     (repl-buf (get-buffer julia-snail-repl-buffer))
     (send-return t)
     (async t)
     (polling-interval 20)
     (polling-timeout julia-snail-async-timeout))
  "Insert str directly into the REPL buffer. When :async is nil,
wait for the REPL prompt to return, otherwise return immediately."
  (declare (indent defun))
  (unless repl-buf
    (user-error "No Julia REPL buffer %s found; run julia-snail" julia-snail-repl-buffer))
  (let ((pre-write-size (buffer-size repl-buf)))
    (with-current-buffer repl-buf
      (julia-snail--terminal-send-string str)
      (when send-return (julia-snail--terminal-send-return)))
    (unless async
      ;; wait for the buffer to accept the new input, or a race condition may
      ;; occur with non-async prompt check below
      (julia-snail--wait-while (= pre-write-size (buffer-size repl-buf)) polling-interval polling-timeout)
      ;; wait for the inclusion to succeed (i.e., the prompt prints)
      (julia-snail--wait-while
       (with-current-buffer repl-buf
         (not (julia-snail--looking-back-string "julia> ")))
       polling-interval
       polling-timeout))))

(cl-defun julia-snail--send-to-server
    (module
     str
     &key
     (repl-buf (get-buffer julia-snail-repl-buffer))
     (marker (point-marker))
     (async t)
     (async-poll-interval 20)
     (async-poll-maximum julia-snail-async-timeout)
     (display-error-buffer-on-failure? t)
     babel-props
     (redirect-io t)
     (queue t)
     srcbuf-ov
     callback-success
     callback-failure
     callback-stream
     callback-display)
  "Send STR to Snail server, and evaluate it in the context of MODULE.
Run callback-success and callback-failure as appropriate.
When :async is t (default), return the request id. When :async is
nil, wait for the result and return it."
  (declare (indent defun))
  
  (unless repl-buf
    (user-error "No Julia REPL buffer %s found; run julia-snail" julia-snail-repl-buffer))

  (when (and babel-props srcbuf-ov)
    (user-error "At most one of `babel-props` and `srcbuf-ov` must be passed."))
  
  (let* ((process-buf (get-buffer (julia-snail--process-buffer-name repl-buf)))
         (module-ns (julia-snail--construct-module-path module))
         (reqid (format "%04x%04x" (random (expt 16 4)) (random (expt 16 4))))
         (code-str (json-encode-string str))
         (display-code-str (if julia-snail-debug
                               code-str
                             (s-truncate 80 code-str)))
         (origin-str (cond
                      (babel-props
                       (json-encode-string
                        (format "Babel(%s, %S)"
                                (julia-snail-ob-params->named-tuple
                                 (plist-get babel-props :params))
                                (plist-get babel-props :output-file))))
                      (srcbuf-ov
                       (json-encode-string "Srcbuf()"))
                      (t "nothing")))
         (redirect-io-str (if redirect-io "true" "false"))
         (queue-str (if queue "true" "false"))
         (msg (format "(ns = %s, reqid = \"%s\", code = %s, origin = %s, redirectio = %s, queue = %s)\n"
                      module-ns
                      reqid
                      code-str
                      origin-str
                      redirect-io-str
                      queue-str))
         (display-msg (format "(ns = %s, reqid = \"%s\", code = %s, origin = %s, redirectio = %s, queue = %s)\n"
                              module-ns
                              reqid
                              display-code-str
                              origin-str
                              redirect-io-str
                              queue-str))
         (res-sentinel (gensym))
         (res res-sentinel)
         (req (let* ((stream-buf (generate-new-buffer
                                  (format " *julia-snail-stream-%s*" reqid)))
                     (data (make-julia-snail-request-data
                            :stream-buf stream-buf
                            :finalizer (make-finalizer
                                        (lambda ()
                                          (when (buffer-live-p stream-buf)
                                            (kill-buffer stream-buf))))))
                     (srcbuf-ov (when (and srcbuf-ov (marker-buffer marker))
                                  (with-current-buffer (marker-buffer marker)
                                    (julia-snail-srcbuf-ov-display
                                     (car srcbuf-ov)
                                     (cdr srcbuf-ov)
                                     data)))))
                (make-julia-snail-request
                 :id reqid
                 :repl-buf repl-buf
                 :marker marker
                 :babel-props babel-props
                 :srcbuf-ov srcbuf-ov
                 :data data
                 :display-error-buffer-on-failure? display-error-buffer-on-failure?
                 :callback-stream callback-stream
                 :callback-display callback-display
                 :callback-success
                 (lambda (req result)
                   (unless async
                     (setq res (or result :nothing)))
                   (when (and callback-success (marker-buffer marker))
                     (with-current-buffer (marker-buffer marker)
                       (funcall callback-success req result))))
                 :callback-failure
                 (lambda (req msg stack)
                   (unless async (setq res :nothing))
                   (when (and callback-failure (marker-buffer marker))
                     (with-current-buffer (marker-buffer marker)
                       (funcall callback-failure req msg stack))))))))
    (with-current-buffer process-buf
      (goto-char (point-max))
      (insert display-msg))
    (process-send-string process-buf msg)
    (spinner-start 'progress-bar)
    (puthash reqid req julia-snail--requests)

    (if async
        req
      ;; XXX: Non-async (i.e. synchronous) server requests need to poll the
      ;; response. This means they can either (1) succeed, (2) timeout, or (3)
      ;; error out. Because errors occur in the process filter function and
      ;; therefore outside the scope of a potential condition-case, they must be
      ;; processed with a non-local transfer of control (throw and catch).
      (let ((wait-result
             (catch 'julia-snail--server-filter-error
               (julia-snail--wait-while (eq res-sentinel res) async-poll-interval async-poll-maximum))))
        ;; wait-result can be t if poll succeeded, nil if it timed out, and an
        ;; error if something blew up. Note that an explicit check for t is
        ;; necessary here because wait-result can be truthy but nevertheless an
        ;; error. This happens if an error value is caught in the `catch'.
        (if (eq t wait-result)
            res
          (let ((error-msg (if (null wait-result)
                               "Snail command timed out"
                             (format "Snail error: %s" wait-result))))
            (when callback-failure
              (funcall callback-failure req "Snail command timed out" nil))
            (with-current-buffer (marker-buffer marker)
              (spinner-stop))
            (error error-msg)))))))

(cl-defun julia-snail--send-to-server-via-tmp-file
    (module
     str
     filename
     line-num
     &key
     (repl-buf (get-buffer julia-snail-repl-buffer))
     queue
     callback-success
     callback-failure)
  "Send STR to server by first writing it to a tmpfile, calling
Julia include on the tmpfile, and then deleting the file. The
code in the tmpfile will be parsed in Julia as if it were
actually located in FILENAME starting at LINE-NUM and will be
evaluated in the context of MODULE."
  (declare (indent defun))
  (let* ((text (concat "begin\n" (s-trim str) "\nend\n"))
         (module-ns (julia-snail--construct-module-path module))
         (tmpfile (make-temp-file
                   (expand-file-name "julia-tmp" ; NOT julia-snail--efn
                                     (or small-temporary-file-directory
                                         (temporary-file-directory)))))
         (tmpfile-local-remote (file-remote-p tmpfile 'localname)))
    (progn
      (with-temp-file tmpfile
        (insert text))
      (let ((req (julia-snail--send-to-server
                     :Main
                     (format "Main.JuliaSnail.eval_tmpfile(\"%s\", %s, \"%s\", %s)"
                             (or tmpfile-local-remote tmpfile)
                             module-ns
                             filename
                             line-num)
                     :repl-buf repl-buf
                     ;; TODO: Only async via-tmp-file evaluation is currently
                     ;; supported because we rely on getting the reqid back from
                     ;; julia-snail--send-to-server, and that only happens with
                     ;; (async t). This may or may not be worth fixing in the
                     ;; future.
                     :async t
                     :queue queue
                     :callback-success callback-success
                     :callback-failure callback-failure)))
        ;; Update the request info to include tmpfile tracking
        (setf (julia-snail-request-tmpfile reqtr) tmpfile)
        (setf (julia-snail-request-tmpfile-local-remote reqtr) tmpfile-local-remote)
        req))))

(defun julia-snail--server-response-filter (proc str)
  "Snail process filter for PROC given input STR; used as argument to `set-process-filter'."
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      ;; Insert at the end unconditionally
      (goto-char (point-max))
      (insert str)
      (set-marker (process-mark proc) (point))
      ;; Need to read and eval the value sent in by the process (str). But it
      ;; may have been chunked. Assume that a successful read signals the end of
      ;; input, but a failed read needs to be concatenated to other upcoming
      ;; reads. Track them in a table hashed by the proc.
      (let ((candidate (s-concat (gethash proc julia-snail--proc-responses) str))
            (pos 0))
        (while (< pos (length candidate))
          (condition-case-unless-debug err
              (let* ((res (read-from-string candidate pos))
                     (read-str (car res))
                     (next-pos (cdr res)))
                (setq pos next-pos)
                (if (< pos (length candidate))
                    (puthash proc (substring candidate pos) julia-snail--proc-responses)
                  (remhash proc julia-snail--proc-responses))
                (eval read-str))
            (end-of-file
             (puthash proc (substring candidate pos) julia-snail--proc-responses)
             (setq pos (length candidate)))
            (error
             (throw 'julia-snail--server-filter-error err))))))))


;;;; Server response handling

;; When a request is send to evaluate some code, we can get various kind of
;; responses:
;; 1. Request response: The final evaluation result
;; 2. Stdout and stderr stream
;; 3. Multimedia displays

;;;;; Request response

(defun julia-snail--response-base (reqid)
  "Snail response handler for REQID, base function."
  (when-let* ((request (gethash reqid julia-snail--requests)))
    (when-let* ((tmpfile (julia-snail-request-tmpfile request)))
      (delete-file tmpfile))
    (with-current-buffer (marker-buffer (julia-snail-request-marker request))
      (spinner-stop))
    (remhash reqid julia-snail--requests)))

(defun julia-snail--response-success (reqid result)
  "Snail success response handler for REQID given RESULT."
  (let* ((request (gethash reqid julia-snail--requests))
         (data (julia-snail-request-data request)))
    (when (and data result)
      (setf (julia-snail-request-data-result data) result))
    (when-let* ((callback-success (julia-snail-request-callback-success request)))
      (funcall callback-success request result)))
  (julia-snail--response-base reqid))

(defun julia-snail--response-failure (reqid error-message &optional error-stack)
  "Snail failure response handler for REQID with ERROR-MESSAGE and ERROR-STACK."
  (let* ((request (gethash reqid julia-snail--requests))
         (data (julia-snail-request-data request)))
    (setf (julia-snail-request-data-error-message data) error-message
          (julia-snail-request-data-error-stack data) error-stack)
    (when (julia-snail-request-display-error-buffer-on-failure? request)
      (let* ((repl-buf (julia-snail-request-repl-buf request))
             (process-buf (get-buffer (julia-snail--process-buffer-name repl-buf)))
             (error-buffer (julia-snail--message-buffer
                            repl-buf "error" error-stack)))
        (julia-snail--setup-compilation-mode
         error-buffer
         (gethash process-buf julia-snail--cache-proc-basedir))
        (pop-to-buffer error-buffer)))
    (when-let* ((callback (julia-snail-request-callback-failure request)))
      (funcall callback request error-message error-stack)))
  (julia-snail--response-base reqid))

(defun julia-snail--response-interrupt (reqid)
  "Snail task interruption response handler for REQID."
  (julia-snail--response-base reqid))

;;;;; Stdout and stderr stream

;; TODO Encode stderr text with red face
(defun julia-snail--response-stream (reqid type chunk)
  "Store the stream CHUNK of request with id REQID in its data slot.

This handles escape sequences, though ansi coloring is not applied, as
this uses overlays which cannot be copied over with (buffer-string)."
  (when-let* ((req (gethash reqid julia-snail--requests))
              (data (julia-snail-request-data req))
              (buf (julia-snail-request-data-stream-buf data)))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (buffer-undo-list t) ; dont record undos
            (start (point-max)))

        (goto-char start)
        (insert chunk)
        
        ;; Rewind to the beginning of the line where we started inserting.
        ;; This fixes the bug where chunks ending in \n caused the cursor 
        ;; to jump to a blank line and skip processing entirely
        (setq start (save-excursion
                      (goto-char start)
                      (line-beginning-position)))
        
        ;; Handle Carriage Returns (\r)
        ;; Delete the old text before the \r so it can't bleed through
        (goto-char start)
        (while (search-forward "\r" nil t)
          (delete-region (line-beginning-position) (point)))
        
        ;; Handle 'Clear to End of Line' (\e[K or \033[K)
        (goto-char start)
        (while (re-search-forward "\033\\[K" nil t)
          (replace-match "")
          (delete-region (point) (line-end-position)))
        
        (goto-char (point-max))))
    (when-let* ((callback (julia-snail-request-callback-stream req)))
      (funcall callback req type))))

;;;;; Display

;; TODO Integrate with multimedia code

(defun julia-snail--response-display (reqid type value meta result-p)
  (when-let* ((req (gethash reqid julia-snail--requests))
              (data (julia-snail-request-data req))
              (display (julia-snail-request-make-display
                        req type value meta result-p)))
    (push display (julia-snail-request-data-displays data))
    (when-let* ((callback (julia-snail-request-callback-display req)))
      (funcall callback req display))))


;;;; CST parser interface

(defun julia-snail--cst-module-at (buf pt)
  (let* ((byteloc (position-bytes pt))
         (encoded (julia-snail--encode-base64 buf))
         (res (julia-snail--send-to-server
                :Main
                (format "JuliaSnail.CST.moduleat(\"%s\", %d)" encoded byteloc)
                :async nil)))
    (if (eq res :nothing)
        nil
      res)))

(defun julia-snail--cst-block-at (buf pt)
  (let* ((byteloc (position-bytes pt))
         (encoded (julia-snail--encode-base64 buf))
         (res (julia-snail--send-to-server
                :Main
                (format "JuliaSnail.CST.blockat(\"%s\", %d)" encoded byteloc)
                :async nil)))
    (if (eq res :nothing)
        nil
      res)))

(defun julia-snail--cst-includes (buf)
  (let* ((encoded (julia-snail--encode-base64 buf))
         (pwd (file-name-directory (julia-snail--efn (buffer-file-name buf))))
         (res (julia-snail--send-to-server
                :Main
                (format "JuliaSnail.CST.includesin(\"%s\", \"%s\")" encoded pwd)
                :async nil))
         (includes (make-hash-table :test #'equal)))
    (unless (eq res :nothing)
      (cl-loop for (file modules) in (-partition 2 res) do
               (puthash file modules includes)))
    ;; TODO: Maybe there's a situation in which returning :error is appropriate?
    includes))

(defun julia-snail--cst-code-tree (buf)
  (let* ((encoded (julia-snail--encode-base64 buf))
         (res (julia-snail--send-to-server
                :Main
                (format "JuliaSnail.CST.codetree(\"%s\")" encoded)
                :async nil)))
    res))


;;;; Module tracking

(defun julia-snail--module-merge-includes (current-filename includes)
  "Update file module cache using INCLUDES tree parsed from CURRENT-FILENAME."
  (let* ((process-buf (get-buffer (julia-snail--process-buffer-name julia-snail-repl-buffer)))
         (proc-includes (or (gethash process-buf
                                     julia-snail--cache-proc-implicit-file-module)
                            (puthash process-buf (make-hash-table :test #'equal)
                                     julia-snail--cache-proc-implicit-file-module)))
         (current-file-module (gethash (julia-snail--efn current-filename) proc-includes)))
    ;; merge includes with the proc-includes table
    (cl-loop for included-file being the hash-keys of includes using (hash-values included-file-modules) do
             (puthash included-file
                      (if current-file-module
                          (append current-file-module included-file-modules)
                        included-file-modules)
                      proc-includes))
    ;; done
    proc-includes))

(defun julia-snail--module-for-file (file)
  "Retrieve the module for FILE from `julia-snail--cache-proc-implicit-file-module' table."
  (let* ((filename (julia-snail--efn file))
         (process-buf (get-buffer (julia-snail--process-buffer-name julia-snail-repl-buffer)))
         (proc-includes (gethash process-buf julia-snail--cache-proc-implicit-file-module
                                 (make-hash-table :test #'equal)))
         (parent-modules (gethash filename proc-includes (list))))
    parent-modules))

(cl-defgeneric julia-snail--module-at-point (&optional partial-module)
  "Return the current Julia module at point as an Elisp list, including PARTIAL-MODULE if given."
  (or partial-module '("Main")))

(cl-defmethod julia-snail--module-at-point
  (&context (major-mode julia-mode) &optional partial-module)
  (let ((partial-module (or partial-module
                            (julia-snail--cst-module-at (current-buffer) (point)))))
    (if (buffer-file-name (buffer-base-buffer))
        (let ((module-for-file (julia-snail--module-for-file (buffer-file-name (buffer-base-buffer)))))
          (or (if module-for-file
                  (append module-for-file partial-module)
                partial-module)
              '("Main")))
      (or partial-module '("Main")))))


;;;; Xref

(defun julia-snail-xref-backend ()
  "Emacs xref API: return the Snail xref backend when Snail is usable."
  (and julia-snail-mode
       (get-buffer julia-snail-repl-buffer)
       'xref-julia-snail))

(cl-defmethod xref-backend-identifier-at-point ((_backend (eql xref-julia-snail)))
  "Emacs xref API."
  (julia-snail--identifier-at-point))

(cl-defmethod xref-backend-identifier-completion-table ((_backend (eql xref-julia-snail)))
  "Emacs xref API."
  (let* ((module (julia-snail--module-at-point))
         (ns (s-join "." module)))
    (julia-snail--send-to-server
      module
      (format "Main.JuliaSnail.lsnames(%s, all=true, imported=true, include_modules=false, recursive=true)" ns)
      :async nil)))

(defun julia-snail--make-xrefs-helper (response)
  "Emacs xref API helper for RESPONSE."
  (if (or (null response) (eq :nothing response))
      nil
    (mapcar (lambda (candidate)
              (let* ((descr (-first-item candidate))
                     (path (-second-item candidate))
                     (line (-third-item candidate))
                     ;; convert to Tramp path when working with a remote REPL
                     (tramp-prefix (file-remote-p default-directory))
                     (real-path (if tramp-prefix
                                    (concat tramp-prefix path)
                                  path)))
                (xref-make descr
                           (if (file-exists-p real-path)
                               (xref-make-file-location real-path line 0)
                             (xref-make-bogus-location "xref location not found")))))
            response)))

(cl-defmethod xref-backend-definitions ((_backend (eql xref-julia-snail)) identifier)
  "Emacs xref API."
  (unless identifier
    (user-error "No identifier at point"))
  (let* ((module (julia-snail--module-at-point))
         ;; Grab everything in the identifier up to the last dot, i.e., the
         ;; fully-qualified module name, and everything after the last dot,
         ;; which should be the symbol in the module.
         (identifier-split (save-match-data
                             (if (string-match
                                  "\\(.*\\)\\.\\(.*\\)"
                                  identifier)
                                 (list (match-string 1 identifier)
                                       (match-string 2 identifier))
                               (list module identifier))))
         (identifier-ns (-first-item identifier-split))
         (identifier-ns-real (cond ((listp identifier-ns)
                                    (-last-item identifier-ns))
                                   ((null identifier-ns)
                                    "Main")
                                   (t
                                    identifier-ns)))
         (identifier-name (-second-item identifier-split))
         (res (julia-snail--send-to-server
                module
                (format "Main.JuliaSnail.lsdefinitions(%s, \"%s\")"
                        identifier-ns-real identifier-name)
                :async nil)))
    (julia-snail--make-xrefs-helper res)))

;; TODO: Implement this. See
;; https://discourse.julialang.org/t/finding-uses-of-a-method/32729/3 for
;; information about how it can be done. Key points: (1) It is most reliable
;; for executed code, which is of course a non-starter for IDE functionality.
;; (2) It can be done by iterating through all methods in all modules and
;; calling Base.uncompressed_ast and looking for appropriate calls. Seems like
;; it won't be accurate for functions called through indirection, but would
;; definitely be a step in the right direction.
(cl-defmethod xref-backend-references ((_backend (eql xref-julia-snail)) _identifier)
  nil)

(cl-defmethod xref-backend-apropos ((_backend (eql xref-julia-snail)) pattern)
  (let ((res (julia-snail--send-to-server
               :Main
               (format "Main.JuliaSnail.apropos(%s, \"%s\")"
                       "Main"
                       pattern)
               :async nil)))
    (julia-snail--make-xrefs-helper res)))


;;;; Completion

(defun julia-snail--repl-completions (identifier &optional module-finder)
  (let* ((module (if module-finder (apply module-finder (list)) (julia-snail--module-at-point)))
         (res (julia-snail--send-to-server
                :Main
                (format "try; JuliaSnail.replcompletion(\"%1$s\", %2$s); catch; JuliaSnail.replcompletion(\"%1$s\", Main); end"
                        identifier
                        (s-join "." module))
                :async nil)))
    (if (eq :nothing res)
        (list)
      res)))

(defun julia-snail-repl-completion-at-point (&optional module-finder)
  "Implementation for Emacs `completion-at-point' system using REPL.REPLCompletions as the provider."
  (let ((identifier (julia-snail--identifier-at-point))
        (bounds (julia-snail--identifier-at-point-bounds))
        (repl-buf (get-buffer julia-snail-repl-buffer))
        (split-on "\\.")
        (prefix "")
        start)
    (when (and bounds repl-buf)
      ;; If identifier starts with a backslash we need to add an extra "\\" to
      ;; make sure that the string which arrives to the completion provider on the server starts with "\\".
      (when (s-equals-p (substring identifier 0 1) "\\")
        (setq prefix "\\"))
      ;; If identifier is not a string, we split on "." so that completions of
      ;; the form Module.f -> Module.func work (since
      ;; `julia-snail--repl-completions' will return only "func" in this case)
      (setq start (- (cdr bounds) (length (car (last (s-split split-on identifier))))))
      (list start
            (cdr bounds)
            (completion-table-dynamic
             (lambda (_) (julia-snail--repl-completions (concat prefix identifier) module-finder)))
            :exclusive 'no))))


;;;; Imenu

;; TODO: Add marginalia metadata. Use completion-extra-properties
;; :annotation-function for this? How, exactly?

(defun julia-snail--imenu-helper (tree modules)
  (when tree
    (let* ((first-node (car tree))
           (first-node (if (eq 'quote (car first-node))
                           (cadr first-node)
                         first-node))
           (first-node-type (nth 0 first-node))
           (first-node-name (nth 1 first-node))
           (first-node-location (byte-to-position (nth 2 first-node))))
      (cons
       (if (eq 'module (car first-node))
           (cons
            (if (eq :module-tree julia-snail-imenu-style)
                first-node-name
              (cons
               (format "module %s" (s-join "." (append modules (list first-node-name))))
               first-node-location))
            (julia-snail--imenu-helper
             (nth 3 first-node)
             (append modules (list first-node-name))))
         (cons
          (if (eq :module-tree julia-snail-imenu-style)
              (format "%s %s" first-node-type first-node-name)
            (format "%s %s" first-node-type
                    (s-join "." (append modules (list first-node-name)))))
          first-node-location))
       (julia-snail--imenu-helper (cdr tree) modules)))))

(defun julia-snail--imenu-included-module-helper (normal-tree)
  ;; XXX: This fugly kludge transforms imenu trees in a way that injects modules
  ;; cached through include()ed files at the root:
  ;;
  ;; if included-modules is ("Alpha" "Bravo")
  ;; and normal-tree is ((function "f1" ...))
  ;; then this returns (("Alpha" ("Bravo" (function "f1" ...))))
  ;;
  ;; There must be a cleaner way to implement this logic.
  (let ((included-modules (julia-snail--module-for-file (buffer-file-name (buffer-base-buffer)))))
    (cl-labels ((some-helper
                 (incls norms first-time)
                 (if (null incls)
                     norms
                   (let* ((next (some-helper (cdr incls) norms nil))
                          (tail (cons (car incls) (if first-time(list next) next))))
                     (if first-time (list tail) tail)))))
      (some-helper included-modules normal-tree t))))

(cl-defun julia-snail-imenu ()
  ;; exit early if Snail's imenu integration is turned off, or no Snail session is running
  (unless (and julia-snail-imenu-style (get-buffer julia-snail-repl-buffer))
    (cl-return-from julia-snail-imenu
      (funcall julia-snail--imenu-fallback-index-function)))
  ;; check the cache and debounce
  (when julia-snail--imenu-cache
    (when (or
           ;; unmodified buffer
           (= (julia-snail--imenu-cache-entry-tick julia-snail--imenu-cache)
              (buffer-modified-tick))
           ;; it hasn't been long enough since the last modification (5 seconds)
           (< (- (float-time) (julia-snail--imenu-cache-entry-timestamp julia-snail--imenu-cache))
              5.0))
      (cl-return-from julia-snail-imenu
        (julia-snail--imenu-cache-entry-value julia-snail--imenu-cache))))
  ;; cache miss: ask Julia to parse the file and return the imenu index
  (let* ((code-tree (julia-snail--cst-code-tree (current-buffer)))
         (imenu-index-raw (julia-snail--imenu-included-module-helper (julia-snail--imenu-helper code-tree (list))))
         (imenu-index (if (eq :flat julia-snail-imenu-style)
                          (-flatten imenu-index-raw)
                        imenu-index-raw)))
    ;; update the cache
    (setq julia-snail--imenu-cache
          (make-julia-snail--imenu-cache-entry
           :timestamp (float-time)
           :tick (buffer-modified-tick)
           :value imenu-index))
    ;; return the result
    imenu-index))

;;;; Overlays in source buffers

;; NOTE Majority copy-pasted from emacs-jupyter!
;; Show evaluation streams, displays, and result as overlays in source buffers.
;; The overlay wraps the code region that was evaluated. The 'after-string
;; property is used to display the result.

(defface julia-snail-srcbuf-overlay
  '((((class color) (min-colors 88) (background light))
     :foreground "navy"
     :weight bold)
    (((class color) (min-colors 88) (background dark))
     :foreground "dodger blue"
     :weight bold))
  "Face used for the evaluation result overlays in source buffers."
  :group 'julia-snail)

(defvar-keymap julia-snail-srcbuf-overlay-keymap
  :doc "Keymap for source buffer overlays."
  "S-RET" 'julia-snail-srcbuf-ov-toggle-folding
  "S-<return>" 'julia-snail-srcbuf-ov-toggle-folding
  "M-RET" 'julia-snail-srcbuf-ov-toggle-showing
  "M-<return>" 'julia-snail-srcbuf-ov-toggle-showing
  )

(defconst julia-snail-srcbuf-ov-property 'julia-snail-eval
  "Overlay property that holds `julia-snail-srcbuf-ov-state'.")

(cl-defstruct julia-snail-srcbuf-ov-state
  data ; julia-snail-request-data struct
  (folded-p t) ; else expanded
  showing ; nil, 'stream, 'result, or integer indicating display index
  )

(defun julia-snail-srcbuf-ov--delete (ov &rest _)
  (delete-overlay ov))

(defun julia-snail-srcbuf-ov--remove-all (beg end)
  (dolist (ov (overlays-in beg end))
    (when (overlay-get ov julia-snail-srcbuf-ov-property)
      (julia-snail-srcbuf-ov--delete ov))))

(defun julia-snail-srcbuf-ov--propertize (text &optional newline)
  ;; Display properties can't be nested so use the one on TEXT if available
  (if (get-text-property 0 'display text)
      text
    (let ((display (concat
                    ;; Add a space before a newline so that `point' stays on
                    ;; the same line when moving to the beginning of the
                    ;; overlay.
                    (if newline " \n" " ")
                    (propertize
                     julia-snail-srcbuf-overlay-prefix
                     'face 'julia-snail-srcbuf-overlay)
                    ;; TODO This removes ansi applied colors, not sure how to fix it.
                    ;; add-face-text-property doesnt work.
                    ;; text
                    (propertize
                     text
                     'face 'julia-snail-srcbuf-overlay)
                    )))
      ;; (add-face-text-property 0 (length display) 'underline t display)
      
      ;; Ensure `point' doesn't move past the beginning or end of the overlay
      ;; on motion commands.
      (put-text-property 0 1 'cursor t display)
      (put-text-property (1- (length display)) (length display) 'cursor t display)
      
      (propertize " " 'display display))))

(defun julia-snail-srcbuf-ov--fold-boundary (text)
  "Returns position of TEXT where remained should be invisible."
  (string-match-p "\n" text))

(defun julia-snail-srcbuf-ov--fold-string (text)
  "Add the 'invisible property to all but first part of TEXT.
What consitutes the first part is determined using `julia-snail-srcbuf-ov--fold-boundary'."
  (when (eq buffer-invisibility-spec t)
    (setq buffer-invisibility-spec '(t)))
  (unless (assoc julia-snail-srcbuf-ov-property buffer-invisibility-spec)
    (push (cons julia-snail-srcbuf-ov-property t) buffer-invisibility-spec))
  (when-let* ((pos (julia-snail-srcbuf-ov--fold-boundary text)))
    (put-text-property pos (length text) 'invisible julia-snail-srcbuf-ov-property text))
  text)

(defun julia-snail-srcbuf-ov--expand-string (text)
  "Removes the 'invisble property from TEXT."
  (prog1 text
    (put-text-property 0 (length text) 'invisible nil text)))

(defun julia-snail-srcbuf-ov--clean-string (text)
  (thread-last
    text
    (replace-regexp-in-string "\n+$" "")
    (replace-regexp-in-string "^\n+" "")))

(defun julia-snail-srcbuf-ov--string (state)
  "Return the string that will be displayed in the 'after-string ov property."
  (pcase-let* (((cl-struct julia-snail-srcbuf-ov-state
                           data showing folded-p) state)
               ((cl-struct julia-snail-request-data
                           stream-buf displays result) data)
               (display (when (numberp showing) (nth showing displays)))
               (text (cond
                      ((eq showing 'stream)
                       (with-current-buffer stream-buf (buffer-string)))
                      ((eq showing 'result)
                       result)
                      ((and display
                            (eq (julia-snail-request-display-type display) :text))
                       (julia-snail-request-display-value display))
                      ((and display folded-p)
                       (format "%s" (julia-snail-request-display-type display))))))
    (cond
     (text
      (let* ((text (thread-last
                     text
                     julia-snail-srcbuf-ov--clean-string
                     ansi-color-apply)))
        (cond
         (folded-p
          (julia-snail-srcbuf-ov--propertize
           (julia-snail-srcbuf-ov--fold-string text)))
         ((julia-snail-srcbuf-ov--fold-boundary text)
          (julia-snail-srcbuf-ov--propertize
           ;; Newline added so that background extends across entire line
           ;; of the last line in TEXT.
           (concat (julia-snail-srcbuf-ov--expand-string text) "\n")
           t))
         (t
          (julia-snail-srcbuf-ov--propertize
           (julia-snail-srcbuf-ov--expand-string text))))))
     (t
      (with-slots (type value meta) display
        (pcase type
          (:image
           (let* ((img-data (base64-decode-string value))
                  (img-type (intern (plist-get meta :ext)))
                  (img (cons 'image (list :type img-type :data img-data))))
             (concat "\n" (propertize " " 'display img))))
          (:latex
           (let* ((path (org-latex-preview-create-images value))
                  (img (cons 'image (list :type 'svg :file path))))
             (concat "\n" (propertize " " 'display img))))))))))

(defun julia-snail-srcbuf-ov--update (ov)
  "Update overlay to reflect the state of the overlay data."
  (when-let* ((buf (overlay-buffer ov)) ; nil if buf dead
              (state (overlay-get ov julia-snail-srcbuf-ov-property))
              (options (julia-snail-request-data-options
                        (julia-snail-srcbuf-ov-state-data state))))
    (with-slots (data showing) state
      (unless (julia-snail-srcbuf-ov-state-showing state)
        (setf (julia-snail-srcbuf-ov-state-showing state) (car options)))
      (setf (overlay-get ov 'after-string)
            (julia-snail-srcbuf-ov--string state)))))

(defun julia-snail-srcbuf-ov--make (beg end req-data)
  (let ((ov (make-overlay beg end nil t))
        (state (make-julia-snail-srcbuf-ov-state :data req-data)))
    (overlay-put ov 'evaporate t)
    (overlay-put ov 'modification-hooks '(julia-snail-srcbuf-ov--delete))
    (overlay-put ov 'insert-in-front-hooks '(julia-snail-srcbuf-ov--delete))
    (overlay-put ov 'insert-behind-hooks '(julia-snail-srcbuf-ov--delete))
    (overlay-put ov 'keymap julia-snail-srcbuf-overlay-keymap)
    (overlay-put ov julia-snail-srcbuf-ov-property state)
    (julia-snail-srcbuf-ov--update ov)
    ov))

(defun julia-snail-srcbuf-ov--nearest ()
  (let (nearest)
    (dolist (ov (overlays-at (point)))
      (when (and (or (null nearest)
                     (and (> (overlay-start ov) (overlay-start nearest))
                          (< (overlay-end ov) (overlay-end nearest))))
                 (overlay-get ov julia-snail-srcbuf-ov-property))
        (setq nearest ov)))
    nearest))

(defun julia-snail-srcbuf-ov--print-state (state)
  "Print to the message buffer what data type is currently shown."
  (pcase-let* (((cl-struct julia-snail-srcbuf-ov-state
                           data showing folded-p) state)
               (options (julia-snail-request-data-options data))
               ((cl-struct julia-snail-request-data
                           stream-buf displays result) data)
               (n-displays (length displays))
               (stream-empty-p (= 0 (buffer-size stream-buf)))
               (face-emph 'minibuffer-prompt)
               (face-muted 'shadow))
    (if (null options)
        (message "No results")
      (message
       "%s: %s"
       (if folded-p "Folded" "Expanded")
       (with-work-buffer
         (dolist (type options)
           (cond
            ((eq type 'stream)
             (insert
              (propertize
               "Stream"
               'face (if (eq showing 'stream) face-emph face-muted))))
            ((numberp type)
             (insert
              " "
              (propertize
               (format "Display %s" (1+ type))
               'face (if (and (numberp showing)
                              (= showing type)) face-emph face-muted))))
            ((eq type 'result)
             (insert
              " "
              (propertize
               "Result"
               'face (if (eq showing 'result) face-emph face-muted))))))
         (buffer-string))))))

(defun julia-snail-srcbuf-ov-refresh (ov)
  "Update overlay to reflect the state of the overlay data."
  (when-let* ((state (overlay-get ov julia-snail-srcbuf-ov-property)))
    (julia-snail-srcbuf-ov--update ov)
    (julia-snail-srcbuf-ov--print-state state)))

(defun julia-snail-srcbuf-ov-toggle-folding ()
  "Expand or contract the display of evaluation results around `point'."
  (interactive)
  (when-let* ((ov (julia-snail-srcbuf-ov--nearest))
              (state (overlay-get ov julia-snail-srcbuf-ov-property)))
    (julia-snail--flash-region (overlay-start ov) (overlay-end ov))
    (with-slots (folded-p) state
      (setf (julia-snail-srcbuf-ov-state-folded-p state)
            (if folded-p nil t)))
    (julia-snail-srcbuf-ov-refresh ov)))

(defun julia-snail-srcbuf-ov-toggle-showing ()
  "Toggle between stream, displays, and returned result."
  (interactive)
  (when-let* ((ov (julia-snail-srcbuf-ov--nearest))
              (state (overlay-get ov julia-snail-srcbuf-ov-property))
              (options (julia-snail-request-data-options
                        (julia-snail-srcbuf-ov-state-data state))))
    (let* ((showing (julia-snail-srcbuf-ov-state-showing state))
           (idx (cl-position showing options))
           (new-showing (cond
                         ((= 1 (length options))
                          (car options))
                         ((= idx (1- (length options)))
                          (car options))
                         (t
                          (nth (1+ idx) options)))))
      (setf (julia-snail-srcbuf-ov-state-showing state) new-showing)
      (julia-snail-srcbuf-ov-refresh ov))
    (julia-snail--flash-region (overlay-start ov) (overlay-end ov))))

(defun julia-snail-srcbuf-ov-remove-all ()
  "Remove all evaluation result overlays in the buffer."
  (interactive)
  (julia-snail-srcbuf-ov--remove-all (point-min) (point-max)))

(defun julia-snail-srcbuf-ov-remove (&optional remove-all)
  (interactive "P")
  (if remove-all
      (julia-snail-srcbuf-ov-remove-all)
    (when-let* ((ov (julia-snail-srcbuf-ov--nearest)))
      (julia-snail-srcbuf-ov--delete ov))))

(defun julia-snail-srcbuf-ov-display (beg end req-data)
  "Overlay (BEG . END) of request data REQ-DATA."
  (save-excursion
    (goto-char end)
    (skip-syntax-backward "->")
    (setq end (point))
    (julia-snail-srcbuf-ov--remove-all (1- end) end)
    (julia-snail-srcbuf-ov--make beg end req-data)))

(defun julia-snail-srcbuf-ov-p ()
  "Return non-nil if evaluation results should be displayed with overlays."
  (and julia-snail-srcbuf-overlays julia-snail-repl-buffer))


;;;; Completion modes' auxiliary doc modes

;; company-quickhelp and corfu-doc

(defun julia-snail--completions-doc-buffer (str)
  (let* ((module (julia-snail--module-at-point))
         (name (s-concat (s-join "." module) "." str))
         (doc (julia-snail--send-to-server
                :Main
                (format "@doc %s" name)
                :display-error-buffer-on-failure? nil
                :async nil)))
    (let ((buf (julia-snail--message-buffer
                julia-snail-repl-buffer
                "doc-buffer"
                (if (eq :nothing doc)
                    "Documentation not found!\nDouble-check your package activation and imports."
                  doc)
                :markdown t)))
      (with-current-buffer buf
        (julia-snail--add-to-perspective buf)
        (font-lock-ensure))
      buf)))

(defun julia-snail-completions-doc-capf ()
  (interactive)
  (let* ((comp (julia-snail-repl-completion-at-point))
         (doc (list :company-doc-buffer
                    #'julia-snail--completions-doc-buffer)))
    (cl-concatenate 'list comp doc)))


;;;; Eldoc

(defun julia-snail-eldoc ()
  "Implementation for ElDoc."
  ;; TODO: Implement something reasonable. This is pretty tricky to do in a
  ;; world of generic functions, since the parser will need to do the work of
  ;; figuring out just which possible signatures of a function are being called
  ;; and display documentation accordingly.
  nil
)

;;;; Multimedia

(defun julia-snail-multimedia-display (img &optional reqid)
  (let* ((repl-buf (get-buffer julia-snail-repl-buffer))
         (style (buffer-local-value 'julia-snail-multimedia-buffer-style repl-buf))
         (mm-buf-name-base (format "%s mm" (buffer-name repl-buf)))
         (mm-buf-name (if (memq style '(:single-reuse :multi))
                          mm-buf-name-base
                        (generate-new-buffer-name mm-buf-name-base)))
         (mm-buf (get-buffer-create mm-buf-name))
         (decoded-img (base64-decode-string img)))
    (when (bound-and-true-p julia-snail--repl-go-back-target)
      (with-current-buffer julia-snail--repl-go-back-target
        (spinner-stop)))
    (with-current-buffer mm-buf
      ;; allow directly-inserted images to be erased
      (fundamental-mode)
      (read-only-mode -1)
      (when (eq :single-reuse style)
        (erase-buffer))
      (when (memq style '(:single-reuse :single-new))
        ;; use image-mode
        (insert decoded-img)
        (image-mode))
      (when (eq :multi style)
        ;; insert images as objects
        ;; switching from previously-used :single-reuse requires special cleanup
        (when (eq 'image-mode major-mode)
          (erase-buffer)
          (fundamental-mode))
        ;; check buffer size and insert separator as needed
        (when (> (buffer-size) 0)
          (goto-char (point-max))
          (insert "\n\n"))
        (if (image-type-available-p 'imagemagick)
            (let ((shortest (car
                             (-sort
                              (lambda (a b)
                                (< (window-height a)
                                   (window-height b)))
                              (get-buffer-window-list mm-buf)))))
              (if shortest
                  (insert-image (create-image decoded-img 'imagemagick t :height (round (* 0.80 (window-pixel-height shortest)))))
                (insert-image (create-image decoded-img 'imagemagick t))))
          (insert-image (create-image decoded-img nil t))))
      (dolist (win (get-buffer-window-list mm-buf))
        (set-window-point win (point-max)))
      (read-only-mode 1)
      (julia-snail-multimedia-buffer-mode 1)
      (setq-local julia-snail-multimedia-source-reqid reqid))
    (display-buffer mm-buf)
    (when julia-snail-multimedia-buffer-autoswitch
      (pop-to-buffer mm-buf))))

(defun julia-snail-multimedia-toggle-display-in-emacs ()
  "Turn Julia multimedia display in Emacs off or on."
  (interactive)
  (unless (display-images-p)
    (user-error "This Emacs display does not support images"))
  (let ((repl-buf (get-buffer julia-snail-repl-buffer)))
    (message
     (julia-snail--send-to-server
       '("JuliaSnail" "Multimedia")
       "display_toggle()"
       :repl-buf repl-buf
       :async nil))))


;;;; Formatter

(defun julia-snail--format-text (txt)
  (julia-snail--send-to-server
    '("JuliaSnail" "Formatter")
    (let* ((ubs (string-as-unibyte txt))
           (estr (base64-encode-string ubs))
           (pathstr (base64-encode-string (buffer-file-name))))
      (format "format_data(\"%s\", \"%s\")" estr  pathstr))
    :async nil))

(defun julia-snail-format-region (begin end)
  "Format region delimited by BEGIN and END using JuliaFormatter.jl.
The code in the region must be syntactically valid Julia, otherwise no formatting will take place."
  (interactive "r")
  (let* ((text-to-be-formatted (buffer-substring-no-properties begin end))
         (ftext (julia-snail--format-text text-to-be-formatted)))
    (if (eq :nothing ftext)
        (message "Parsing error, formatting failed")
      (delete-region begin end)
      (insert ftext))))

(defun julia-snail-format-buffer ()
  "Format buffer using JuliaFormatter.jl.
The buffer must be syntactically valid Julia, otherwise no formatting will take place.
Point placement after reformatting is sketchy, since the code might have changed quite a bit."
  (interactive)
  (let* ((old-point (point)))
    (julia-snail-format-region (point-min) (point-max))
    (goto-char old-point)))

(defvar julia-snail-formatter-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c j f r") #'julia-snail-format-region)
    (define-key map (kbd "C-c j f b") #'julia-snail-format-buffer)
    map))

(define-minor-mode julia-snail-formatter-mode
  "Julia Snail JuliaFormatter.jl integration."
  :init-value nil
  :lighter ""
  :keymap julia-snail-formatter-mode-map)

;;;; Extensions

(defun julia-snail--extension-symbol (extname)
  (intern (format "julia-snail/%s" extname)))

(defun julia-snail--extension-init (extname)
  (intern (format "%s-init" (julia-snail--extension-symbol extname))))

(defun julia-snail--extension-mode (extname)
  (intern (format "%s-mode" (julia-snail--extension-symbol extname))))

(defun julia-snail--extension-load (extname)
  (let ((extsym (julia-snail--extension-symbol extname)))
    (unless (featurep extsym)
      (let* ((current-file (locate-library "julia-snail"))
             (extdir (concat (file-name-directory current-file)
                             (file-name-as-directory "extensions")
                             (file-name-as-directory (symbol-name extname))))
             (load-path (append load-path (list extdir)))
             (extfile (concat extdir (symbol-name extname) ".el")))
        (require extsym extfile)))))


;;;; Commands

;;;###autoload
(defun julia-snail ()
  "Start a Julia REPL and connect to it, or switch if one already exists.
The following buffer-local variables control it:
- `julia-snail-repl-buffer' (default: *julia*)
- `julia-snail-port' (default: 10011)
To create multiple REPLs, give these variables distinct values (e.g.:
*julia my-project-1* and 10012)."
  (interactive)
  (let ((source-buf (current-buffer))
        (repl-buf (get-buffer julia-snail-repl-buffer)))
    (if repl-buf
        ;; Julia session exists
        (progn
          (with-current-buffer repl-buf
            (setq julia-snail--repl-go-back-target source-buf))
          (pop-to-buffer repl-buf))
      ;; run a new Julia REPL in a terminal and load the Snail server file
      (unless julia-snail-port
        (setq-local julia-snail-port (1+ julia-snail-port-counter))
        (setq julia-snail-port-counter (1+ julia-snail-port-counter)))
      (julia-snail--start source-buf))))

(defun julia-snail-send-line ()
  "Send the line at point to the Julia REPL and evaluate it.
Without a prefix arg, evaluation occurs in the context of the current module.
If one prefix arg is used (C-u), evaluation occurs in the context of the Main module.
If two or more prefix args are used (C-u C-u), the code is instead copied directly into the REPL, and evaluation occurs in the context of the Main module."
  (interactive)
  (let ((block-start (line-beginning-position))
        (block-end (line-end-position)))
    (unless (eq block-start block-end)
      (julia-snail--send-helper
       block-start block-end
       :message-prefix "Line evaluated"))))

(defun julia-snail-send-region ()
  "Send the region (requires transient-mark) to the Julia REPL and evaluate it.
Without a prefix arg, evaluation occurs in the context of the current module.
If one prefix arg is used (C-u), evaluation occurs in the context of the Main module.
If two or more prefix args are used (C-u C-u), the code is instead copied directly into the REPL, and evaluation occurs in the context of the Main module."
  (interactive)
  (if (null (use-region-p))
      (user-error "No region selected")
    (let ((block-start (region-beginning))
          (block-end (region-end)))
      (julia-snail--send-helper
       block-start block-end
       :message-prefix "Selected region evaluated"))))

(defun julia-snail-send-code-cell (block-start block-end)
  "Send the current code cell to the Julia REPL and run it in the context of the current module.
Code cells is a notebook-style feature implemented with
https://github.com/astoff/code-cells.el. code-cells-mode must be
enabled for this to work, and something like this is required for
activation:
(add-to-list 'code-cells-eval-region-commands '(julia-snail-mode . julia-snail-send-code-cell))"
  (julia-snail--send-helper
   block-start block-end))

(defun julia-snail-send-top-level-form ()
  "Send the top level form around the point to the Julia REPL and evaluate it.
This occurs in the context of the current module.
Currently only works on blocks terminated with `end'."
  (interactive)
  (let* ((q (julia-snail--cst-block-at (current-buffer) (point)))
         (filename (julia-snail--efn (buffer-file-name (buffer-base-buffer))))
         (module (julia-snail--module-at-point (-first-item q)))
         (block-start (byte-to-position (or (-second-item q) -1)))
         (block-end (byte-to-position (or (-third-item q) -1)))
         (top-level-form-name (or (-fourth-item q) nil))
         (line-num (line-number-at-pos block-start))
         (text (condition-case nil
                   (buffer-substring-no-properties block-start block-end)
                 (error ""))))
    (if (null q)
        (user-error "No top-level form at point")
      (julia-snail--flash-region block-start block-end)
      (julia-snail--send-to-server-via-tmp-file
        module
        text
        filename
        line-num
        :callback-success (lambda (_request-info &optional data)
                            (message "Top-level form evaluated: %s; module %s"
                                     (if top-level-form-name
                                         top-level-form-name
                                       "unknown")
                                     (julia-snail--construct-module-path module)))))))

(defun julia-snail-copy-last-eval-result ()
  "Copy the latest inline evaluation result for the current buffer to the kill ring."
  (interactive)
  (unless julia-snail--last-eval-result
    (user-error "No inline evaluation result available"))
  (kill-new julia-snail--last-eval-result)
  (message "Copied latest inline evaluation result"))

(defun julia-snail-send-dwim ()
  "Send region, block, or line to Julia REPL."
  (interactive)
  (if (use-region-p)                    ; region
      (julia-snail-send-region)
    (condition-case _err                ; block
        (julia-snail-send-top-level-form)
      (user-error                       ; block fails, so send line
       (julia-snail-send-line)))))

(defun julia-snail-send-buffer-file ()
  "Send the current buffer's file into the Julia REPL, and include() it.
This will occur in the context of the Main module, just as it would at the REPL."
  (interactive)
  (let* ((jsrb-save julia-snail-repl-buffer) ; save for callback context
         (filename (julia-snail--efn (buffer-file-name (buffer-base-buffer))))
         (module (or (julia-snail--module-for-file filename) '("Main")))
         (includes (julia-snail--cst-includes (current-buffer))))
    (when (or (not (buffer-modified-p))
              (y-or-n-p (format "'%s' is not saved, send to Julia anyway? " filename)))
      (julia-snail--send-to-server
        module
        (format "include(\"%s\"); Main.JuliaSnail.elexpr(true)" filename)
        :callback-success (lambda (_request-info &optional _data)
                            ;; julia-snail-repl-buffer must be rebound here from
                            ;; jsrb-save, because the callback will run in a
                            ;; different scope, in which the correct binding of
                            ;; julia-snail-repl-buffer will have disappeared
                            (let* ((julia-snail-repl-buffer jsrb-save)
                                   (repl-buf (get-buffer julia-snail-repl-buffer)))
                              ;; NB: At the moment, julia-snail--cst-includes
                              ;; does not return :error. However, it might in
                              ;; the future, and this code will then be useful.
                              (if (eq :error includes)
                                  (let ((error-buffer
                                         (julia-snail--message-buffer
                                          repl-buf
                                          "error"
                                          (concat filename
                                                  " loaded in Julia, but the Snail parser failed.\n\n"
                                                  "Please report this as a parser bug:\n\n"
                                                  "https://github.com/gcv/julia-snail/issues\n\n"
                                                  "Please try to narrow down the code which Snail fails to parse.\n"
                                                  "The easiest way of doing this is to bisect the failing source file by\n"
                                                  "commenting out successive halves.\n"
                                                  "The more information about code which Snail cannot parse you include in the bug\n"
                                                  "report, the easier it will be to fix."))))
                                    (pop-to-buffer error-buffer))
                                ;; successful load
                                (julia-snail--module-merge-includes filename includes)
                                (message "%s loaded: module %s"
                                         filename
                                         (julia-snail--construct-module-path module)))))))))

;; Trimmed down version of julia-snail-send-buffer-file which only analyzes the "include" statements without running the code
(defun julia-snail-analyze-includes ()
  "Analyze the current buffer's file for include statements"
  (interactive)
  (let* ((filename (julia-snail--efn (buffer-file-name (buffer-base-buffer))))
         (includes (julia-snail--cst-includes (current-buffer))))
    (when (or (not (buffer-modified-p))
              (y-or-n-p (format "'%s' is not saved, analyze in Julia anyway? " filename)))
      (if (eq :error includes)
          (let ((error-buffer
                 (julia-snail--message-buffer
                  repl-buf
                  "error"
                  (concat filename
                          " analyzed in Julia, but the Snail parser failed.\n\n"
                          "Please report this as a parser bug:\n\n"
                          "https://github.com/gcv/julia-snail/issues\n\n"
                          "Please try to narrow down the code which Snail fails to parse.\n"
                          "The easiest way of doing this is to bisect the failing source file by\n"
                          "commenting out successive halves.\n"
                          "The more information about code which Snail cannot parse you include in the bug\n"
                          "report, the easier it will be to fix."))))
            (pop-to-buffer error-buffer))
        ;; successful load
        (julia-snail--module-merge-includes filename includes)))))

(defun julia-snail-package-activate (dir)
  "Activate a Pkg project located in DIR in the Julia REPL."
  (interactive "DProject directory: ")
  (let ((expanded-dir (julia-snail--efn dir)))
    (julia-snail--send-to-server
      :Main
      (format "Pkg.activate(\"%s\")" expanded-dir)
      :callback-success (lambda (_request-info &optional _data)
                          (message "Package activated: %s" expanded-dir)))))

(defun julia-snail-doc-lookup (identifier)
  "Look up Julia documentation for symbol at point (IDENTIFIER)."
  (interactive (list (read-string
                      "Documentation look up: "
                      (unless current-prefix-arg (julia-snail--identifier-at-point)))))
  (let* ((module (julia-snail--module-at-point))
         (name (s-concat (s-join "." module) "." identifier))
         (doc (julia-snail--send-to-server
                :Main
                (format "@doc %s" name)
                :display-error-buffer-on-failure? nil
                :async nil)))
    (pop-to-buffer (julia-snail--message-buffer
                    julia-snail-repl-buffer
                    (format "documentation: %s" identifier)
                    (if (eq :nothing doc)
                        "Documentation not found!\nDouble-check your package activation and imports."
                      doc)
                    :markdown t))))

(defun julia-snail-repl-go-back ()
  "Return to a source buffer from a Julia REPL buffer."
  (interactive)
  (when (bound-and-true-p julia-snail--repl-go-back-target)
    (pop-to-buffer julia-snail--repl-go-back-target)))

(defun julia-snail-repl-terminal-kill-line ()
  "Make kill-line (C-k by default) save content to the kill ring."
  (interactive)
  (cond
   ;; Eat
   ((eq 'eat-mode major-mode)
    (kill-ring-save (point) (line-end-position))
    (eat-self-input 1 ?\C-k)
    )
   ;; vterm
   ((eq 'vterm-mode major-mode)
    (kill-ring-save (point) (vterm-end-of-line))
    (vterm-send-key "k" nil nil t))
   ;; ghostel
   ((eq 'ghostel-mode major-mode)
    (if buffer-read-only
        ;; When a ghostel buffer is in emacs input mode or copy input mode, the
        ;; buffer is marked as read only, and C-k is bound to the usual
        ;; `kill-line', so we'll do the same here.
        (kill-line)
      ;; Otherwise, it is in a terminal-like mode, so we put content on the yank
      ;; ring and then send the C-k key.
      (progn
        (kill-ring-save (point) (line-end-position))
        (ghostel-send-key "k" "ctrl"))))
   ;; error and debugging
   (t
    (error "function called out of context; (with-current-buffer repl-buf ...) required"))))

(defun julia-snail-clear-caches ()
  "Clear connection-specific internal Snail xref, completion, and module caches.
Useful if something seems to wrong."
  (interactive)
  (when (or julia-snail-mode julia-snail-repl-mode)
    (let ((process-buf (get-buffer (julia-snail--process-buffer-name
                                    (if julia-snail-mode
                                        julia-snail-repl-buffer
                                      (current-buffer))))))
      (julia-snail--clear-proc-caches process-buf))))

(defun julia-snail-update-module-cache ()
  "Update cache of implicit modules referenced in current source file.
This is not necessary when files are loaded into the Julia
environment using `julia-snail-send-buffer-file', but it is
useful for a workflow using Revise.jl. It makes xref and
autocompletion aware of the available modules."
  (interactive)
  (let* ((filename (julia-snail--efn (buffer-file-name (buffer-base-buffer))))
         (module (or (julia-snail--module-for-file filename) '("Main")))
         (includes (julia-snail--cst-includes (current-buffer))))
    (julia-snail--module-merge-includes filename includes)
    (message "Caches updated: parent module %s"
             (julia-snail--construct-module-path module))))

(defun julia-snail-interrupt-task ()
  "Try to interrupt a Julia computation task which was started on the Emacs side."
  (interactive)
  (let* ((running-reqids (hash-table-keys julia-snail--requests))
         ;; TODO: Filter these reqids for valid ones (e.g. ones with valid REPL buffers?)
         (reqid (cond ((= 0 (length running-reqids))
                       (message "No Julia tasks currently running (that the Emacs side knows about)")
                       nil)
                      ((= 1 (length running-reqids))
                       (-first-item running-reqids))
                      (t
                       (completing-read "Select id of Julia request to interrupt"
                                        ;; TODO: This needs to include metadata and annotations for what
                                        ;; computational task each reqid corresponds to (like a line number
                                        ;; or the actual code).
                                        running-reqids)))))
    (when reqid
      (let* ((repl-buf (get-buffer julia-snail-repl-buffer))
             (resp (julia-snail--send-to-server
                     '("JuliaSnail" "Tasks")
                     (format "interrupt(\"%s\")" reqid)
                     :repl-buf repl-buf
                     :async nil))
             (res (car resp)))
        (if res
            (message "Interrupt scheduled for Julia reqid %s" reqid)
          (message "Unknown reqid %s on the Julia side" reqid)
          (remhash reqid julia-snail--requests))))))


;;;; Keymaps

(defvar julia-snail-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-z") #'julia-snail)
    (define-key map (kbd "C-c C-a") #'julia-snail-package-activate)
    (define-key map (kbd "C-c C-d") #'julia-snail-doc-lookup)
    (define-key map (kbd "C-c C-w") #'julia-snail-copy-last-eval-result)
    (define-key map (kbd "C-c C-c") #'julia-snail-send-top-level-form)
    (define-key map (kbd "C-M-x") #'julia-snail-send-top-level-form)
    (define-key map (kbd "C-c C-r") #'julia-snail-send-region)
    (define-key map (kbd "C-c C-l") #'julia-snail-send-line)
    (define-key map (kbd "C-c C-e") #'julia-snail-send-dwim)
    (define-key map (kbd "C-c C-k") #'julia-snail-send-buffer-file)
    (define-key map (kbd "C-c C-m u") #'julia-snail-update-module-cache)
    map))

(defvar julia-snail-repl-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-z") #'julia-snail-repl-go-back)
    (define-key map (kbd "C-k") #'julia-snail-repl-terminal-kill-line)
    map))


;;;; Mode menu

(easy-menu-define julia-snail-mode-menu julia-snail-mode-map
  "Julia-Snail mode menu."
  '("Snail"
    ["Switch to REPL" julia-snail]
    ["Activate package" julia-snail-package-activate]
    ["Lookup documentation" julia-snail-doc-lookup]
    ["Copy last inline result" julia-snail-copy-last-eval-result]
    ["Update module cache" julia-snail-update-module-cache]
    "---"
    ["Evaluate line" julia-snail-send-line]
    ["Evaluate top-level form" julia-snail-send-top-level-form]
    ["Evaluate region" julia-snail-send-region :active (region-active-p)]
    ["Evaluate file" julia-snail-send-buffer-file]))

(easy-menu-define julia-snail-repl-mode-menu julia-snail-repl-mode-map
  "Julia-Snail REPL mode menu."
  '("Snail REPL"
    ["Switch to source" julia-snail-repl-go-back]))


;;;; Mode definitions

;;;###autoload
(define-minor-mode julia-snail-mode
  "A minor mode for interactive Julia development.
Should only be turned on in source buffers.

The following keys are set:
\\{julia-snail-mode-map}"
  :init-value nil
  :lighter (:eval (julia-snail--mode-lighter))
  :keymap julia-snail-mode-map
  (if julia-snail-mode
      ;; activate
      (progn
        (julia-snail--enable)
        (add-hook 'xref-backend-functions #'julia-snail-xref-backend nil t)
        (add-function :before-until (local 'eldoc-documentation-function) #'julia-snail-eldoc)
        (advice-add 'spinner-print :around #'julia-snail--spinner-print-around)
        (setq julia-snail--imenu-fallback-index-function imenu-create-index-function)
        (setq imenu-create-index-function 'julia-snail-imenu)
        (if (and (or (locate-library "company-quickhelp")
                     (locate-library "corfu-doc") ; deprecated; keeping around for backwards compatibility
                     )
                 julia-snail-completions-doc-enable)
            (add-hook 'completion-at-point-functions #'julia-snail-completions-doc-capf nil t)
          (add-hook 'completion-at-point-functions #'julia-snail-repl-completion-at-point nil t)))
    ;; deactivate
    (remove-hook 'completion-at-point-functions #'julia-snail-completions-doc-capf t)
    (remove-hook 'completion-at-point-functions #'julia-snail-repl-completion-at-point t)
    (setq imenu-create-index-function julia-snail--imenu-fallback-index-function)
    (setq julia-snail--imenu-fallback-index-function nil)
    (advice-remove 'spinner-print #'julia-snail--spinner-print-around)
    (remove-function (local 'eldoc-documentation-function) #'julia-snail-eldoc)
    (remove-hook 'xref-backend-functions #'julia-snail-xref-backend t)
    (julia-snail--disable)))

;;;###autoload
(define-minor-mode julia-snail-repl-mode
  "A minor mode for interactive Julia development.
Should only be turned on in REPL buffers.

The following keys are set:
\\{julia-snail-repl-mode-map}"
  :init-value nil
  :lighter (:eval (julia-snail--mode-lighter))
  :keymap julia-snail-repl-mode-map
  (when (or (eq 'vterm-mode major-mode)
            (eq 'eat-mode major-mode)
            (eq 'ghostel-mode major-mode))
    (if julia-snail-repl-mode
        (julia-snail--repl-enable)
      (julia-snail--repl-disable))))

(define-minor-mode julia-snail-message-buffer-mode
  "A minor mode for displaying messages returned from the Julia REPL."
  :init-value nil
  :lighter (:eval (julia-snail--mode-lighter " Message"))
  :keymap '(((kbd "q") . quit-window)))

(define-minor-mode julia-snail-multimedia-buffer-mode
  "A minor mode for displaying Julia multimedia output an Emacs buffer."
  :init-value nil
  :lighter (:eval (julia-snail--mode-lighter " MM"))
  :keymap '(((kbd "q") . quit-window)))

;;;; Org babel

(require 'julia-snail-ob)

;;;; Footer

(provide 'julia-snail)

;;; julia-snail.el ends here
