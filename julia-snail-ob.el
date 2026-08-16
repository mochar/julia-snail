;;; julia-snail-ob --- Org Babel support for Julia Snail

;;; Commentary:

;; This package adds Julia Snail support to Org Mode src block evaluation.

;; Mostly a copy-paste of karthink/ob-julia. Changes:
;; - Simplified heavily as it only supports Snail (no ESS)
;; - All calls are use a session

;;; Code:

;;;; Requires

(require 'ob)
(require 'subr-x)
(require 'cl)
(require 'cl-generic)

;;;; Variables

(defgroup julia-snail-ob nil
  "Org babel support for Julia Snail."
  :group 'julia-snail
  :version "24.1")

(defcustom julia-snail-ob-after-async-execute-hook nil
  "Hook run after async execution of Julia babel blocks."
  :group 'julia-snail-ob
  :type 'hook)

(defcustom julia-snail-ob-latexify-star-environments t
  "Insert an asterisk in the environment name of generated LaTeX.
By default, latexify's outermost environment is usually unstarred, e.g.
\\begin{environment}. When set, this will insert an asterisk at the end of
the environment name, i.e. \\begin{environment*}."
  :type 'boolean
  :group 'julia-snail-ob)

(defcustom julia-snail-ob-force-latex-environment t
  "When using the latexify header argument, change the type of
LaTeX environment used in the result to `equation'. See also
`julia-snail-ob-latexify-star-environments'."
  :type 'boolean
  :group 'julia-snail-ob)

(defconst org-babel-header-args:julia
  '((width		 . :any)
    (height		 . :any)
    (size		 . :any)
    (let		 . :any)
    (async		 . :any)
    (results		 . ((file matrix table list verbatim)
			    (raw html latex org)
			    (replace silent none append prepend)
			    (output value))))
  "Julia-specific header arguments.")

(setq org-babel-default-header-args:julia
      '((:module . "Main")
        (:session . nil)
        (:async   . "yes")
        ;; (:results . "scalar")
        ))

(defconst julia-snail-ob-mimes->exts
  '(("text/org"  . "org")
   ("text/csv"  . "csv")
   ("image/eps"  . "eps")
   ("text/html" . "html")
   ("text/org"  . "org")
   ("application/pdf"  . "pdf")
   ("image/png"  . "png")
   ("application/postscript" . "ps")
   ("image/svg+xml"  . "svg")
   ("application/x-tex"  . "tex"))
  "Alist of extensions to mimetypes used by Julia when writing to
  files.")

;; Set default extension to tangle Julia code:
(add-to-list 'org-babel-tangle-lang-exts '("julia" . "jl"))

;;;; Org functions
;; Argument handling, error display etc

(defun julia-snail-ob-params->named-tuple (params)
  "Takes the arguments in PARAMS that needs to be processed by
Julia, and put them in a NamedTuple() that will be passed to Julia."
  (defun param->julia (param &optional julia-name)
    "Takes the org parm named PARAM from params and return an
equivalent Julia assignment.  The value will be assigned to
JULIA_NAME when not nil.  Elisp types are converted to Julia
equivalents."
    (let* ((name (symbol-name param))
           (name (or julia-name
                     (substring name 1 (length name))))
           (val (alist-get param params))
           (val (if val
                    (format "%S" val)
                  "nothing")))
      (format "%s=%s" (subst-char-in-string ?- ?_ name) val)))
  ;; Create a named tuple (the comma is required to make it a tuple
  ;; if only one element is present)
  (format "(%s,)"
          (mapconcat 'concat
                     (list
                      (param->julia :dir)
                      (param->julia :results)
                      (param->julia :module "target_module") ; module is reserved
                      ;; Optional arguments.  We pass them all and let
                      ;; julia decide what to do
                      (param->julia :latexify)
                      (param->julia :size)
                      (param->julia :width)
                      (param->julia :height)
                      (param->julia :output-dir)
                      (param->julia :file-ext))
                     ", ")))

(defvar julia-snail-ob--async-map '()
  "Association list between async block uuids and its requried info (evaluation params, buffer).")

(defun julia-snail-ob-prepare-format-call (src-file out-file params &optional uuid)
  "Format a call to OrgBabelEval."
  (format
   "ObJulia.OrgBabelEval(%S,%S,%S,%s);"
   src-file out-file (julia-snail-ob-params->named-tuple params)
   (or (when uuid (format "%S" uuid)) "nothing")))

(defun julia-snail-ob--get-create-trace-buffer ()
  (get-buffer-create "*ob-julia-stacktrace*"))

(defun julia-snail-ob--make-trace-buffer (&optional do-not-pop)
  (let ((buf (julia-snail-ob--get-create-trace-buffer)))
    (with-current-buffer buf
      (special-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (unless do-not-pop
      (pop-to-buffer buf))
    buf))

(defun julia-snail-ob--async-get-remove (uuid)
  "Get UUID from the list of async processes, remove it from
  the list and return its value."
  (let ((el (assoc uuid julia-snail-ob--async-map)))
    (setq julia-snail-ob--async-map (delq el julia-snail-ob--async-map))
    el))

(defun julia-snail-ob--async-add (uuid properties)
  "Register the async background block, identified by UUID with
properties PROPERTIES."
  (setq julia-snail-ob--async-map
        (cons `(,uuid . ,properties) julia-snail-ob--async-map)))

(defun julia-snail-ob--trace-file (output-file)
  (concat output-file ".trace"))

(defun julia-snail-ob--has-stacktrace (output-file)
  (file-exists-p (julia-snail-ob--trace-file output-file)))

(defun julia-snail-ob-create-stacktrace-buffer (stacktrace-file &optional do-not-pop)
  "Display the stacktrace in a new buffer"
  (let ((buf (julia-snail-ob--make-trace-buffer do-not-pop)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (insert-file-contents stacktrace-file)))))

(defun julia-snail-ob-dispatch-output-type (params output-file &optional async)
  ;; First, we have the special case in which the output is a
  ;; stacktrace.  If there's one, open it in a buffer, then continue
  ;; showing the results.
  (when (julia-snail-ob--has-stacktrace output-file)
    ;; TODO: jump to the corresponding src line?
    (julia-snail-ob-create-stacktrace-buffer
     (julia-snail-ob--trace-file output-file) (when async -1)))
  (julia-snail-ob-process-results params output-file))

(defun org-babel-edit-prep:julia (info)
  (let ((session (cdr (assq :session (nth 2 info)))))
    (when (and session
	       (string-prefix-p "*"  session)
	       (string-suffix-p "*" session))
      (julia-snail-ob-initiate-session session nil))))

(defun org-babel-expand-body:julia (body params)
  "Expand BODY according to PARAMS.  Return the expanded body, a
  string containing the julia we need to evaluate, possibly
  wrapped in a let block with variable assignmenetns."
  (let ((block (and (alist-get :let params) "let"))
        (vars (mapconcat
               'concat (org-babel-variable-assignments:julia params) ";")))
    (concat
     ;; no newline between vars and body
     ;; so that the stacktrace line is aligned
     block " " vars "; " body
     ";\n"
     (if block "end\n" ""))))

(defun julia-snail-ob-output-file (file &optional extension)
  "Return the a path where Julia should store its results.
  The output file is either a temporary file, or the file
  name passed to the :file argument.  It might contain a
  non-existing path (when :output-dir is a non-existing
  directory).
  If EXTENSION is not nil, use it as file extension."
  (if file
      (expand-file-name file)
    (org-babel-process-file-name
     (org-babel-temp-file
      "julia-" (if extension (concat "." extension) nil)))))

(defun julia-snail-ob-process-value-result (results type)
  "Insert hline if needed (combining info from RESULT and TYPE."
  ;; add an hline if the result seems to be a table
  ;; always obay explicit type
  (if (eq type 'table)
      (cons (car results) (cons 'hline (cdr results)))
    results))

(defun julia-snail-ob-parse-result-type (params)
  "Decide how to parse results. Default is \"auto\"
(results can be anything. If \"table\", force parsing as a
table. To force a matrix, use matrix"
  (let* ((results (alist-get :results params))
	 (results (if (stringp results) (split-string results) nil)))
    (cond
     ((and-let* ((l (alist-get :latexify params))
                 ((not (equal l "no")))))
      'raw)
     ((member "table" results) 'table)
     ((member "matrix" results) 'matrix)
     ((member "list" results) 'list)
     ((member "raw" results) 'raw)
     ((member "verbatim" results) 'verbatim)
     (t 'auto))))

(defun julia-snail-ob-parse-output-extension (params)
  (let* ((results (alist-get :results params))
	 (results (if (stringp results) (split-string results) nil)))
    (cond
     ((member "html" results) "html")
     ((member "latex" results) "tex")
     ((member "org" results) "org")
     ;; ((member "graphcis" results) "")
     (t "org"))))

(defun julia-snail-ob-process-results (params output-file)
  "Decides what to insert as result."
  (let ((result-type (julia-snail-ob-parse-result-type params))
        (file (alist-get :file params))
        (res (alist-get :results params)))
    (unless file
      (with-temp-buffer
        (condition-case err
            (progn
              (insert-file-contents output-file)
              (if (eq buffer-file-coding-system 'no-conversion)
                  ;; Must be an image, force :file
                  (prog1 output-file
                    (setf (alist-get :file params) output-file)
                    (push "file" (alist-get :result-params params)))
                ;; Else format result for display
                (delete-file output-file)
                (goto-char (point-min))
                (let* ((suggested-type (buffer-substring-no-properties
                                        (point) (line-end-position)))
                       (result-as-returned
                        (buffer-substring-no-properties
                         (progn (forward-line 1) (point))
                         (point-max)))
                       ;; ;TODO: Is there any edge case this older version handles?
                       ;; (content (split-string
                       ;;           (buffer-substring-no-properties
                       ;;            (point-min) (point-max)) "\n"))
                       ;; (suggested-type (intern (car content)))
                       ;; (result (mapconcat 'concat (cdr content) "\n"))

                       ;; Handle LaTeX output specially
                       (result (julia-snail-ob--maybe-latexify
                                result-as-returned))

                       ;; Either enforce the result-type requested by the
                       ;; user, or use the one provided by julia if 'auto
                       (result-type (if (eq result-type 'auto)
                                        suggested-type
                                      result-type)))
                  ;; Dispatch processing of result based on result-type
                  (pcase result-type
                    ;; ('table
                    ;;  ;; Add hline
                    ;;  (let ((res (car (read-from-string result))))
                    ;;    `(,(car res) hline ,(cdr res))))
                    ('table (car (read-from-string result)))
                    ('matrix (car (read-from-string result)))
                    ('list (car (read-from-string result)))
                    ('verbatim result)
                    ('raw result)
                    (_ result)))))
          (error
           (display-warning 'org-babel
        		    (format "Error reading results: %S" err)
        		    :error)
           nil))))))

(defun julia-snail-ob--maybe-latexify (result)
  "Conditionally process latexified result.

The LaTeX environment is changed depending on the values of the
variables `julia-snail-ob-force-latex-environment' and
`julia-snail-ob-latexify-star-environments'."
  (if  (and julia-snail-ob-force-latex-environment
            (stringp result))
      (cond
       ((or (string-match-p "\\`\\$\\$[^\u0000]+\\$\\$\\'" result)
            (string-match-p "\\`\\$[^\u0000]+\\$\\'" result))
        (setf result (replace-regexp-in-string
                      "\\`\\$\\$?\\([^\u0000]+\\)\\$\\$?\\'"
                      "\\\\begin{equation*}\n\\1\n\\\\end{equation*}"
                      result)))
       ((and julia-snail-ob-latexify-star-environments
             (string-match-p "\\`\\\\begin" result))
        (setf result (replace-regexp-in-string
                      "\\`\\\\begin{\\([a-z]+\\)}\\([^\u0000]+\\)\\\\end{[a-z]+}\n\\'"
                      "\\\\begin{\\1*}\\2\\\\end{\\1*}\n"
                      result)))
       (t result)))
  result)

(defun julia-snail-ob-assign-to-var (name value)
  "Assign VALUE to a variable called NAME."
  (format "%s = %S" name value))

(defun julia-snail-ob-assign-to-array (name array)
  "Create a Julia Array or Matrix (Vector{Any ,2}) from ARRAY and assign
it to NAME."
  (format "%s = [%s]" name
          (if (not (listp (car array)))
              ;; Vector
              (mapconcat (lambda (e) (format "%S" e)) array ", ")
            ;; Array
	    (mapconcat (lambda (line)
                         (mapconcat (lambda (e)
				      (format "%S" e))
				    line " "))
                       array ";"))))

(defun julia-snail-ob-assign-to-var-or-array (var)
  "Assign an org variable as a Julia variable or array."
  (if (listp (cdr var))
      (julia-snail-ob-assign-to-array (car var) (cdr var))
    (julia-snail-ob-assign-to-var (car var) (cdr var))))

(defun julia-snail-ob-assign-to-dict (name column-names values)
  "Create a Dict with lists as values.
Create a Dict where keys are Symbol from COLUMN-NAMES,
values are Array taken from VALUES, and assign it to NAME"
  (format "%s = Dict(%s)" name
	  (mapconcat
	   (lambda (i)
	     (format "Symbol(\"%s\") => [%s]" (nth i column-names)
		     (mapconcat
		      (lambda (line) (format "%S" (nth i line)))
		      values
		      ",")))
	   (number-sequence 0 (1- (length column-names)))
	   ",")))

(defun julia-snail-ob-assign-to-named-tuple (name column-names values)
  "Create a NamedTuple using (; zip([], [])...)"
  (format "%s = [%s]" name
	  (mapconcat
	   (lambda (i)
	     (concat
	      "(; zip(["
	      (mapconcat
	       (lambda (col) (format "Symbol(\"%s\")" col))
	       column-names ", ")
	      "],["
	      (mapconcat
	       (lambda (cell) (format "\"%s\"" cell))
	       (nth i values)
	       ",")
	      "])...)"))
	   (number-sequence 0 (1- (length values))) ", ")))

(defun org-babel-variable-assignments:julia (params)
  "Return list of julia statements assigning the block's variables."
  (let ((vars (org-babel--get-vars params))
	(colnames (alist-get :colname-names params)))
    (mapcar
     (lambda (i)
       (let* ((var (nth i vars))
	      (column-names
	       (car (seq-filter
		     (lambda (cols)
		       (eq (car cols) (car var)))
		     colnames))))
	 (if column-names
	     (if t ;; julia-snail-ob-table-as-dict
		 (julia-snail-ob-assign-to-dict
		  (car var) (cdr column-names) (cdr var))
	       (julia-snail-ob-assign-to-named-tuple
		(car var) (cdr column-names) (cdr var)))
	   (julia-snail-ob-assign-to-var-or-array var))))
     (number-sequence 0 (1- (length vars))))))

(defun julia-snail-ob-async-p (params)
  "Return t if :async is in params and its value is not \"no\"."
  (let ((async (assoc :async params)))
    (and async (not (string-equal (cdr async) "no")))))

(defun julia-snail-ob-get-session-name (params)
  "Extract the session name from the PARAMS.

Always returns a session name, as eval without session is not supported.

Session can be:
 - (:session) -> `julia-snail-repl-buffer' without asteriks
 - (:session name) -> julia NAME"
  (let* ((session (alist-get :session params))
         (name (if (null session)
                   (substring julia-snail-repl-buffer 1 -1)
               (concat "julia " session))))
    name))

(defun julia-snail-ob--place-result (output-file org-buffer uuid params)
  "Place org-babel result in OUTPUT-FILE in ORG-BUFFER.

PARAMS are the parameters of evaluation and UUID identifies the
source block."
  (save-window-excursion
    (switch-to-buffer org-buffer)
    (save-excursion
      (save-restriction
      	;; If it's narrowed, substitution would fail
        (widen)
      	;; search the matching src block
      	(goto-char (point-max))
      	(when (search-backward (concat "julia-async:" uuid) nil t)
      	  ;; remove uuid string if result-type is raw, as ob-core doesn't do it
          (when (member "raw" (alist-get :result-params params))
            (delete-region (match-beginning 0) (match-end 0)))
          ;; remove results
      	  (search-backward "#+end_src")
          ;; insert new one
          (org-babel-insert-result
           (julia-snail-ob-dispatch-output-type params output-file t)   ;=> result string
           (alist-get :result-params params)                      ;=> result params
           (list nil nil params)                                  ;=> block info
           nil "julia")                                           ;=> hash and lang
          (run-hooks 'julia-snail-ob-after-async-execute-hook))))))

;;;; Backend functions

(defun julia-snail-ob-initiate-session (session params)
  "If there is not a current julia process then create one."
  (or (julia-snail-ob--get-live-session (or session ob-julia-default-session-name))
      (julia-snail-ob-prep-session session params)))

(defun org-babel-prep-session:julia (session params)
  "Prepare SESSION according to the header arguments specified in PARAMS."
  (julia-snail-ob-prep-session session params))

(defun julia-snail-ob--get-live-session (session)
  (and-let*
      ((repl-buffer (get-buffer session)) 
       ((buffer-live-p repl-buffer))
       ((buffer-local-value 'julia-snail-repl-mode repl-buffer)))
    repl-buffer))

(defun julia-snail-ob-prep-session (session params)
  (let ((dir (or (alist-get :dir params) default-directory))
        (repl-buffer (julia-snail-ob-get-session-name params)))
    (save-window-excursion
      ;; Only spawn a new Snail process if the REPL buffer doesn't already exist
      (unless (get-buffer repl-buffer)
        (julia-snail))
      repl-buffer)))

(defun julia-snail-ob--ensure-module (session params)
  "Prompt to create the module specified in PARAMS if it does not exist."
  (let ((module (alist-get :module params)))
    (when (and module (not (string= module "Main")) (not (string= module "none")))
      (let* ((repl-buffer (get-buffer session))
             ;; Query Snail synchronously to see if the module exists.
             ;; Returns t if exists, otherwise returns :nothing 
             (exists (julia-snail--send-to-server
                       :Main
                       (format "isdefined(Main, :%s) && isa(getfield(Main, :%s), Module)" module module)
                       :repl-buf repl-buffer
                       :async nil)))
        (unless (eq exists t) ; Explicit because returns :nothing if not exists
          (if (yes-or-no-p (format "Module '%s' does not exist in Main. Create it? " module))
              ;; Create the module synchronously
              (julia-snail--send-to-server
                :Main
                (format "module %s end" module)
                :repl-buf repl-buffer
                :async nil)
            ;; Abort execution if the user says no
            (user-error "Evaluation aborted: Module '%s' does not exist." module)))))))

(defun julia-snail-ob--maybe-rename-output (output-file mime-type params)
  "Possibly rename OUTPUT-FILE with a more suitable extension.

MIME-TYPE is chosen by ObJulia. PARAMS is the list of block
parameters.
 
ObJulia can pick a mime-type better suited to the type of result
generated - for instance, png when writing a GR plot object.
Unless an output file is explicitly specified with the header arg
`:file', we rename the output file to a more suitable extension."
  (if-let* (((not (alist-get :file params)))
            (required-ext (alist-get mime-type julia-snail-ob-mimes->exts
                                     nil nil #'equal))
            ((not (string= (file-name-extension output-file) required-ext)))
            (new-output-file (concat (file-name-sans-extension output-file)
                                     "." required-ext)))
      (progn (rename-file output-file new-output-file 'force)
             new-output-file)
    output-file))

(defun julia-snail-ob-evaluate-in-session:sync
    (session OrgBabelEval-call _block output-file params)
  "Run BODY in session SESSION synchronously."
  (when-let ((mime-type
              (julia-snail--send-to-server
                '("Main")
                OrgBabelEval-call
                :repl-buf (concat "*" session "*")
                :async nil
                :display-error-buffer-on-failure? t
                :redirect-io nil
                )))
    ;; Rename the output file heuristically by mime-type
    (setq output-file (julia-snail-ob--maybe-rename-output output-file mime-type params))
    (if (file-exists-p output-file)
        output-file
      (error "No output produced."))))

(defun julia-snail-ob-evaluate-in-session:async
    (session uuid OrgBabelEval-call _block output properties)
  "Run BODY in session SESSION asynchronously."
  (let ((reqid 
         (julia-snail--send-to-server
           '("Main")
           OrgBabelEval-call
           :repl-buf (concat "*" session "*")
           :async t
           :display-error-buffer-on-failure? t
           :redirect-io nil
           :callback-success #'julia-snail-ob-success-callback
           ;; Currently never called:
           :callback-failure #'julia-snail-ob-failure-callback)))
    (julia-snail-ob--async-add uuid properties)
    (concat "julia-async:" uuid)))

(defun julia-snail-ob-success-callback (request-info result-data)
  "A function that is called when julia-snail response is available."
  (if (not result-data)
      (message "Code block produced no output.")
    (pcase-let ((`(,uuid-string . ,mime-type) (read result-data)))
      (if (string-match ".*ob_julia_async_\\([0-9a-z\\-]+\\).*" uuid-string)
          (let* ((uuid (match-string-no-properties 1 uuid-string))
                 (org-buffer (julia-snail--request-tracker-originating-buf request-info))
                 (display-errors (julia-snail--request-tracker-display-error-buffer-on-failure?
                                  request-info))
                 (properties (julia-snail-ob--async-get-remove uuid))
                 (vals (cdr properties))
                 (params (elt vals 0))
                 (output-file (elt vals 1))
                 ;; (org-buffer (elt vals 2))
                 (src-file (elt vals 3)))
            (unwind-protect
                (progn
                  ;; Rename the output file heuristically by mime-type
                  (setq output-file
                        (julia-snail-ob--maybe-rename-output output-file mime-type params))
                  (julia-snail-ob--place-result output-file org-buffer uuid params))
              (when (and src-file (file-exists-p src-file))
                (delete-file src-file))))))))

;; NOTE: because we catch errors in ObJulia this is never actually called.
;; TODO: Provide an option to not catch errors when using julia-snail?
;; julia-snail's error reporting is pretty slick.
;; NOTE: In that event, we can't access the UUID! Need to think more about this.
(defun julia-snail-ob-failure-callback (request-info)
  (when-let ((tmpfile (julia-snail--request-tracker-tmpfile request-info)))
    (and (file-exists-p tmpfile) (delete-file tmpfile))))

(defun julia-snail-ob-evaluate-in-session
  (session block OrgBabelEval-call uuid params output-file org-buffer src-file)
  "Evaluate BLOCK in session SESSION, starting it if necessary.
If UUID is provided, run the block asynchronously."
  ;; If the session does not exists, start it
  (when (not (julia-snail-ob--get-live-session session))
    (org-babel-prep-session:julia session params))
  (if uuid
      (julia-snail-ob-evaluate-in-session:async
       session uuid OrgBabelEval-call block output-file
       (list params output-file org-buffer src-file))
    (unwind-protect
        (julia-snail-ob-dispatch-output-type
         params
         (julia-snail-ob-evaluate-in-session:sync
          session OrgBabelEval-call block output-file params))
      (when (and src-file (file-exists-p src-file))
        (delete-file src-file)))))

(defun julia-snail-ob--maybe-make-raw (params)
  "Conditionally change the result type to \"raw\" if the \"latexify\"
header argument is present.

Note: PARAMS is modified in the process."
  (when-let* ((latexify (alist-get :latexify params))
              ((not (equal latexify "no"))))
    (message "LaTeX output requested, ignoring result type!")
    (cl-callf (lambda (v) (nconc v '("raw")))
        (alist-get :result-params params))))

;; Main entry point when code is evaluated in an Org Mode buffer
(defun org-babel-execute:julia (block params)
  "Execute a block of julia code using Julia Snail.

BLOCK is the content of the src block
PARAMS are the parameter passed to the block"
  ;; Save excursion as we might open new buffers (e.g. stacktrace)
  ;; TODO: if the block already has a julia-async link, it would be
  ;; nice to interrupt it and start the new one.
  (save-excursion
    (let* ((org-buffer (current-buffer))
           (session (julia-snail-ob-get-session-name params))
           (body (org-babel-expand-body:julia block params))
           (src-file (make-temp-file "ob-julia-" nil ".jl" body))
           (out-format (or (julia-snail-ob-parse-output-extension params)
                           (bound-and-true-p org-export-current-backend)))
           ;; TODO Change this to reqid?
           (uuid (and (julia-snail-ob-async-p params) (org-id-uuid)))
           (output-file
            (julia-snail-ob-output-file
             (unless (cl-intersection '("link" "graphics")
                                      (alist-get :result-params params)
                                      :test #'equal)
               (alist-get :file params))
             out-format))
           (OrgBabelEval-call
            (julia-snail-ob-prepare-format-call
             src-file output-file params uuid)))
      ;; Modify params in place as specified by header-args:
      (julia-snail-ob--maybe-make-raw params) ; Handle latexify header arg
      (julia-snail-ob--ensure-module session params) ; Handle module
      ;; Evaluate block
      (julia-snail-ob-evaluate-in-session
       session block
       OrgBabelEval-call uuid params output-file org-buffer src-file))))

;;;; Org interaction

(defun julia-snail-ob--session-and-module-at-point (&optional info)
  (when-let* ((info (or info (org-babel-get-src-block-info 'no-eval)))
              (_ (string-equal (nth 0 info) "julia"))
              (params (nth 2 info))
              (session (julia-snail-ob-get-session-name params)))
    (cons session (alist-get :module params))))

(cl-defmethod julia-snail--module-at-point
  (&context (major-mode org-mode) &optional partial-module)
  (let ((org-module (cdr (julia-snail-ob--session-and-module-at-point))))
    (or (if org-module
            (append (list org-module) partial-module)
          partial-module)
        '("Main"))))

(cl-defmethod julia-snail--module-at-point
  (&context (major-mode julia-mode) (org-src-mode (eql t)) &optional partial-module)
  (let* ((info (bound-and-true-p org-src--babel-info))
         (params (nth 2 info))
         (org-module (alist-get :module params)))
    (or (if org-module
            (append (list org-module) partial-module)
          partial-module)
        '("Main"))))

(defun julia-snail-ob-doc-lookup ()
  (interactive)
  (pcase-let* ((`(,session . ,module) (julia-snail-ob--session-and-module-at-point))
               (julia-snail-repl-buffer session))
    (call-interactively #'julia-snail-doc-lookup)))

(defun julia-snail-ob-completion-at-point ()
  (when (org-in-src-block-p 'inside)
    (pcase-let* ((`(,session . ,module) (julia-snail-ob--session-and-module-at-point))
                 (julia-snail-repl-buffer session))
      (julia-snail-repl-completion-at-point))))

(defun julia-snail-ob--src-setup ()
  (when (and (eq major-mode 'julia-mode)
             (boundp 'org-src--babel-info))
    (pcase-let* ((`(,session . ,module) (julia-snail-ob--session-and-module-at-point org-src--babel-info)))
      (setq-local julia-snail-repl-buffer session))))

;;;; Minor mode

(defvar-keymap julia-snail-ob-mode-map
  :doc "Keymap for julia-snail-ob-mode."
  "M-i" #'julia-snail-ob-doc-lookup)
  
(define-minor-mode julia-snail-ob-mode
  "Minor mode for interacting with a Julia REPL from an `org-mode' buffer."
  :group 'julia-snail-ob
  :init-value nil
  :keymap julia-snail-ob-mode-map
  (cond
   (julia-snail-ob-mode
    (add-hook 'after-revert-hook 'julia-snail-ob-mode nil t)
    (add-hook 'completion-at-point-functions #'julia-snail-ob-completion-at-point nil t)
    (add-hook 'org-src-mode-hook 'julia-snail-ob--src-setup)
    )
   (t
    (remove-hook 'after-revert-hook 'julia-snail-ob-mode t)
    (remove-hook 'completion-at-point-functions #'julia-snail-ob-completion-at-point t)
    (remove-hook 'org-src-mode-hook 'julia-snail-ob--src-setup)
    )))


;;;; Footer

(provide 'julia-snail-ob)

;;; julia-snail-ob.el ends here

