;;; julia-snail-ob --- Org Babel support for Julia Snail  -*- lexical-binding: t; -*-

;;; Commentary:

;; This package adds Julia Snail support to Org Mode src block evaluation.

;; Mostly a copy-paste of karthink/ob-julia. Changes:
;; - Simplified heavily as it only supports Snail (no ESS)
;; - All calls are use a session

;;; Code:

;;;; Requires

(require 'ob)
(require 'ov)
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

(defcustom julia-snail-ob-resource-directory "./.ob-snail/"
  "Directory used to store automatically generated image files."
  :type 'string
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

(defun julia-snail-ob-prepare-format-call (src-file out-file params &optional uuid)
  "Format a call to OrgBabelEval."
  (format
   "ObJulia.OrgBabelEval(%S,%S,%S,%s);"
   src-file out-file (julia-snail-ob-params->named-tuple params)
   (or (when uuid (format "%S" uuid)) "nothing")))

(defun org-babel-edit-prep:julia (info)
  (let ((session (cdr (assq :session (nth 2 info)))))
    (when (and session
	       (string-prefix-p "*"  session)
	       (string-suffix-p "*" session))
      (julia-snail-ob-initiate-session session nil))))

(defun org-babel-expand-body:julia (body params)
  "Expand BODY according to PARAMS.
Return the expanded body, a string containing the Julia code we need to
evaluate, possibly wrapped in a let block with variable assignments."
  (let ((block (and (alist-get :let params) "let"))
        (vars (mapconcat
               'concat (org-babel-variable-assignments:julia params) ";")))
    (concat
     "begin"
     ;; no newline between vars and body
     ;; so that the stacktrace line is aligned
     block " " vars "; " body
     ";\n"
     (if block "end\n" "")
     "end"
     )
    ))

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
     ;; ((member "graphics" results) "")
     (t "org"))))

(defun julia-snail-ob-process-results (params output-file)
  "Returns processed OUTPUT-FILE contents, or if image, return OUTPUT-FILE
and modify PARAMS to reflect this."
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
                (let* (;; ObJulia.jl adds the suggested type in the first line
                       ;; of the output file.
                       (suggested-type (buffer-substring-no-properties
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
                       ;; TODO Shouldn't suggested-type be interned as it
                       ;; is a string (pcase below assumes symbol), though
                       ;; it falls back on the same result anyways.
                       (result-type (if (eq result-type 'auto)
                                        suggested-type
                                      result-type)))
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

(defun julia-snail-ob-get-module-str (params)
  ;; TODO Need some type of validation
  (let ((module (alist-get :module params)))
    (cond
     ;; Default to Main
     ((or (null module) (string-empty-p module))
      "Main")
     ;; Idea here is that i mainly intend to use Main.X modules.
     ;; So prefixing with "Main." would be cumbersome.
     ;; But this does mean this will fail for anything non-main.
     ((not (s-starts-with-p "Main" module))
      (concat "Main." module))
     (t
      module))))

;;;; Org helpers

;; From `jupyter-org-element-begin-after-affiliated'
(defun julia-snail-ob-element-begin-after-affiliated (element)
  "Return the beginning position of ELEMENT after any affiliated keywords."
  (or (org-element-property :post-affiliated element)
      (org-element-property :begin element)))

;; From `jupyter-org-element-end-before-blanks'
(defun julia-snail-ob-element-end-before-blanks (element)
  "Return the end position of ELEMENT, before any :post-blank lines."
  (- (org-element-property :end element)
     (or (org-element-property :post-blank element) 0)))

;; From `jupyter-org-element-contents-end'
(defun julia-snail-ob-element-contents-end (element)
  "Return the end position for the contents of ELEMENT in the current buffer."
  (or (org-element-property :contents-end element)
      (save-excursion
        (goto-char (julia-snail-ob-element-end-before-blanks element))
        (line-beginning-position 0))))

;;;; Result placement

;; From `jupyter-org-with-point-at'
(defmacro julia-snail-ob-with-point-at (req &rest body)
  "Move to the associated marker of REQ while evaluating BODY.
If the marker points nowhere don't evaluate BODY, just do
nothing and return nil."
  (declare (indent 1) (debug (form body)))
  `(pcase-let (((cl-struct julia-snail-request marker) ,req))
     (when (and (marker-buffer marker) (marker-position marker))
       (org-with-point-at marker
         ,@body))))

(defun julia-snail-ob--remove-placeholder (request)
  (julia-snail-ob-with-point-at request
    (let ((reqid (julia-snail-request-id request)))
      (when (search-forward (concat "julia-async:" reqid) nil t)
        (delete-region (line-beginning-position) (1+ (line-end-position)))))))

(defun julia-snail-ob--goto-result (&optional end-p)
  (goto-char (org-babel-where-is-src-block-result 'insert))
  (forward-line 1) ; Skip past the #+RESULTS line
  (when end-p
    (goto-char (org-babel-result-end)))
  (unless (bolp) (insert "\n")))

(defun julia-snail-ob--format-fixed-width (text)
  (let ((text (format "%s" text)))
    ;; From `org-element-fixed-width-interpreter'
    (concat
     (if (string-empty-p text) ":\n"
       (replace-regexp-in-string "^" ": " text)))))

(defun julia-snail-ob--format-result (type value)
  (if-let* ((orgval (pcase type
                      ('image (format "[[file:%s]]" value)))))
      (cons orgval t)
    (cons value nil)))

(defun julia-snail-ob--insert (type value)
  (pcase-let ((`(,result . ,org-p) (julia-snail-ob--format-result type value))
              (context (org-element-context)))
    (cond
     ;; Empty line below #+RESULTS:
     ((and (eq (org-element-type context) 'keyword)
           (string= (org-element-property :key context) "RESULTS"))
      (let ((beg (point)))
        (insert (if org-p result (julia-snail-ob--format-fixed-width result)) "\n")
        (cons beg (point))))
     ;; Results in fixed-width element (": xxx")
     ((eq (org-element-type context) 'fixed-width)
      (if (not org-p)
          (progn
            (goto-char (org-babel-result-end))
            (let ((beg (point)))
              (insert (julia-snail-ob--format-fixed-width result) "\n")
              (cons beg (point))))
        (insert ":RESULTS:\n")
        (goto-char (org-babel-result-end))
        (let ((beg (point))
              end)
          (insert result "\n")
          (setq end (point))
          (insert ":END:\n")
          (cons beg end))))
     ;; RESULTS drawer. Append within drawer
     ((and (eq (org-element-type context) 'drawer)
           (string= (org-element-property :drawer-name context)
                    "RESULTS"))
      (goto-char (julia-snail-ob-element-contents-end context))
      (let ((beg (point)))
        (insert result "\n")
        (cons beg (point)))))))

(defun julia-snail-ob--place-result (request type result)
  "Place RESULT of julia snail REQUEST."
  (let* ((properties (julia-snail-request-babel-props request))
         (params (plist-get properties :params))
         (output-file (plist-get properties :output-file)))
    (julia-snail-ob-with-point-at request
      (julia-snail-ob--goto-result)
      (julia-snail-ob--insert type result)
      (run-hooks 'julia-snail-ob-after-async-execute-hook))))

;; TODO Place in begin_out / begin_err blocks?
(defun julia-snail-ob--place-stream (request)
  "Places the contents of REQUEST's stream buffer in the results."
  (when-let* ((data (julia-snail-request-data request))
              (stream-buf (julia-snail--request-data-stream-buf data))
              (stream-str (with-current-buffer stream-buf
                            (buffer-string))))
    (julia-snail-ob-with-point-at request
      (julia-snail-ob--goto-result)
      (if-let* ((result-end (org-babel-result-end))
                (stream-ov (car (ov-in 'julia-snail-stream t (point) result-end))))
          (progn
            ;; Replace region with space char, since deleting everything will
            ;; delete the overlay. We could have also replaced it directly with
            ;; the stream buffer content but this leads to weird rendering
            ;; problems with escape codes.
            (replace-region-contents
             (ov-beg stream-ov) (ov-end stream-ov)
             " ")
            (goto-char (ov-beg stream-ov))
            (insert (julia-snail-ob--format-fixed-width stream-str) "\n"))
        (pcase-let* ((`(,beg . ,end) (julia-snail-ob--insert 'raw stream-str))
                     (ov (make-overlay beg end)))
          (overlay-put ov 'evaporate t)
          ;; (overlay-put ov 'face 'dired-marked)
          (overlay-put ov 'julia-snail-stream t))))))

;; NOTE Ended up doing this lazy approach rather than appending results as they
;; come in, which is what the code above is for. It ended up being too fragile
;; (results coming in at the same time, parsing logic, etc). Since we store
;; everything in the request object anyway its easier to just copy it over any
;; time we get something new.
(defun julia-snail-ob-place-results (&optional req)
  "Replace the results with the results stored in REQ's data."
  (when-let* ((req (or req (julia-snail-ob-request-at-point)))
              (data (julia-snail-request-data req)))
    (with-slots (result stream-buf displays) data
      (julia-snail-ob-with-point-at req
        (org-babel-remove-result)
        (julia-snail-ob--goto-result)
        (let ((beg (point))
              (content
               (with-work-buffer
                 (when-let* ((stream-str (with-current-buffer stream-buf
                                           (buffer-string))))
                   (unless (string-empty-p stream-str)
                     (insert stream-str)))
                 (dolist (d displays)
                   (unless (bolp) (insert "\n"))
                   (insert (car (julia-snail-ob--format-result (car d) (cdr d)))))
                 (when result
                   (unless (bolp) (insert "\n"))
                   (insert (format "%s" result)))
                 (buffer-string))))
          (if displays
              (insert ":RESULTS:\n" content "\n:END:\n")
            (insert (julia-snail-ob--format-fixed-width content) "\n"))
          ;; TODO Copy code this code to julia snail
          ;; The jupyter variant doesnt remove the escape codes so that the
          ;; colors are rendered when opening the file again.
          (jupyter-ansi-color-apply-on-region beg (point))
          (org-link-preview nil beg (point))
          )))))

;; From `jupyter-org-request-at-point'
(defun julia-snail-ob-request-at-point ()
  (interactive)
  (when-let* ((context (org-element-context))
              (babel-p (memq (org-element-type context)
                             '(src-block babel-call
                                         inline-babel-call inline-src-block)))
              (pos (julia-snail-ob-element-begin-after-affiliated context))
              (req (get-text-property pos 'julia-snail-request)))
    (when (called-interactively-p 'interactive)
      (pp-eval-expression req))
    req))

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

(defun julia-snail-ob-evaluate-in-session:sync (session module body output-file params)
  "Run BODY in session SESSION synchronously, return (possibly modified) OUTPUT-FILE."
  (when-let ((mime-type
              (julia-snail--send-to-server
                module
                body
                :repl-buf (concat "*" session "*")
                :async nil
                :babel-props (list :params params :output-file output-file)
                :display-error-buffer-on-failure? t
                )))
    ;; Rename the output file heuristically by mime-type
    (setq output-file (julia-snail-ob--maybe-rename-output output-file mime-type params))
    (if (file-exists-p output-file)
        output-file
      (error "No output produced."))))

(defun julia-snail-ob-evaluate-in-session:async (session module body output-file params)
  "Run BODY in session SESSION asynchronously, return placeholder string."
  (let ((req
         (julia-snail--send-to-server
           module
           body
           :repl-buf (concat "*" session "*")
           :async t
           :display-error-buffer-on-failure? t
           :babel-props (list :params params :output-file output-file)
           :marker (copy-marker org-babel-current-src-block-location)
           :callback-success #'julia-snail-ob-success-callback
           :callback-failure #'julia-snail-ob-failure-callback
           :callback-stream #'julia-snail-ob-stream-callback
           :callback-display #'julia-snail-ob-display-callback
           )))
    (put-text-property
     org-babel-current-src-block-location
     (1+ org-babel-current-src-block-location)
     'julia-snail-request req)
    (concat "julia-async:" (julia-snail-request-id req))))

(defun julia-snail-ob-success-callback (request result)
  "A function that is called when julia-snail response is available."
  (julia-snail-ob--remove-placeholder request)
  (when result
    ;; (julia-snail-ob--place-result request 'raw (format "%s" result))
    (julia-snail-ob-place-results request)
    ))

(defun julia-snail-ob-stream-callback (request type)
  (julia-snail-ob--remove-placeholder request)
  ;; (julia-snail-ob--place-stream request)
  (julia-snail-ob-place-results request)
  )

(defun julia-snail-ob-display-callback (request type value)
  (julia-snail-ob--remove-placeholder request)
  ;; (julia-snail-ob--place-result request type value)
  (julia-snail-ob-place-results request)
  )

(defun julia-snail-ob-failure-callback (request)
  (when-let ((tmpfile (julia-snail-request-tmpfile request)))
    (and (file-exists-p tmpfile) (delete-file tmpfile))))

(defun julia-snail-ob--maybe-make-raw (params)
  "Conditionally change the result type to \"raw\" if the \"latexify\"
header argument is present, returns (modified) params either way.

Note: PARAMS is modified in the process."
  (when-let* ((latexify (alist-get :latexify params))
              ((not (equal latexify "no"))))
    (message "LaTeX output requested, ignoring result type!")
    (cl-callf (lambda (v) (nconc v '("raw")))
        (alist-get :result-params params)))
  params)

(defun julia-snail-ob-cleanup-file-links ()
  "Delete the files of image links for the current source block result.
Do this only if the file exists in
`julia-snail-ob-resource-directory'."
  (when-let*
      ((pos (org-babel-where-is-src-block-result))
       (link-re (format "^[ \t]*%s[ \t]*$" org-link-bracket-re))
       (resource-dir (expand-file-name julia-snail-ob-resource-directory)))
    (save-excursion
      (goto-char pos)
      (forward-line)
      (let ((bound (org-babel-result-end)))
        ;; This assumes that images links are bracketed
        (while (re-search-forward link-re bound t)
          (when-let*
              ((path (org-element-property :path (org-element-context)))
               (dir (when (file-name-directory path)
                      (expand-file-name (file-name-directory path)))))
            (when (and (equal dir resource-dir) (file-exists-p path))
              (delete-file path))))))))

(defun org-babel-execute:julia (block params)
  "Execute a block of julia code using Julia Snail.

BLOCK is the content of the src block
PARAMS are the parameter passed to the block"
  (when (member "replace" (assq :result-params params))
    (julia-snail-ob-cleanup-file-links))
  (let* ((params (julia-snail-ob--maybe-make-raw params))
         (session (julia-snail-ob-get-session-name params))
         (module (julia-snail-ob-get-module-str params))
         (body (org-babel-expand-body:julia block params))
         (out-ext (or (julia-snail-ob-parse-output-extension params)
                      (bound-and-true-p org-export-current-backend)))
         (output-file
          (julia-snail-ob-output-file
           (unless (cl-intersection '("link" "graphics")
                                    (alist-get :result-params params)
                                    :test #'equal)
             (alist-get :file params))
           out-ext))
         (babel-params (julia-snail-ob-params->named-tuple params)))

    ;; If the session does not exists, start it
    (unless (julia-snail-ob--get-live-session session)
      (org-babel-prep-session:julia session params))

    ;; Ensure module exists
    (julia-snail-ob--ensure-module session params)

    ;; TODO Add overlay to src block to prevent editing
    (if (julia-snail-ob-async-p params)
        ;; Async execution
        (julia-snail-ob-evaluate-in-session:async
         session module body output-file params)
      ;; Sync execution
      (julia-snail-ob-process-results
       params
       (julia-snail-ob-evaluate-in-session:sync
        session module body output-file params)))))

;;;; Org interaction

(defun julia-snail-ob--session-and-module-at-point (&optional info)
  (when-let* ((info (or info (org-babel-get-src-block-info 'no-eval)))
              (_ (string-equal (nth 0 info) "julia"))
              (params (nth 2 info))
              (session (julia-snail-ob-get-session-name params))
              (module (julia-snail-ob-get-module-str params)))
    (cons session module)))

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

