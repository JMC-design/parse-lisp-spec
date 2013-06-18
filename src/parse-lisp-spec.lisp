(in-package :parse-lisp-spec)

(declaim #.*compile-decl*)

(defvar *current-line-num* nil
  "Dynamic variable used to track the current line number during parsing")

(define-condition spec-error (error)
  ((line          :type integer
                  :initarg :line
                  :initform (error "~s required when creating ~s" :line 'spec-error)
                  :reader spec-error-line
                  :documentation "The line number where the error occurred.")
   (column        :type (or nil integer)
                  :initarg :column
                  :initform nil
                  :reader spec-error-column
                  :documentation "The column index of the line where the error
occurred, if available. Otherwise NIL.")
   (message       :type string
                  :initarg :message
                  :initform (error "~s required when creating ~s" :message 'spec-error)
                  :reader spec-error-message
                  :documentation "The error message")
   (content       :type (or nil string)
                  :initarg :content
                  :initform nil
                  :reader spec-error-content
                  :documentation "The actual spec content where the error
occurred. Either the entire line, or part of it.")
   (content-index :type (or nil integer)
                  :initarg :content-index
                  :initform nil
                  :reader spec-error-content-index
                  :documentation "The position in content closest to the actual error,
or NIL if the information is not available."))
  (:documentation "Error that is raised if there is an error parsing a spec")
  (:report (lambda (condition stream)
             (with-slots (line column message content content-index) condition
               (format stream "Line ~a~@[, column ~a~]: ~a" line column message)
               (when content
                 (format stream "~%~a~%~,,v@a" content content-index "^"))))))

(defun signal-parse-error (message &optional column content content-index)
  (error 'spec-error
         :line *current-line-num*
         :column column
         :message message
         :content content
         :content-index content-index))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun make-lexer-actions-list (definitions)
    (mapcar #'(lambda (definition)
                (destructuring-bind (regex action)
                    definition
                  (list (cl-ppcre:create-scanner (concatenate 'string "^" regex)) action)))
            definitions))

  (defun parse-definition (definition)
    (cond ((keywordp definition)
           `(constantly ',definition))
          ((symbolp definition)
           `(constantly (list ',definition)))
          ((and (listp definition) (listp (car definition)))
           `(lambda ,(car definition) ,@(cdr definition)))
          ((and (listp definition) (eq (car definition) 'lambda))
           definition)
          (t
           (error "Illegal definition: ~s" definition))))

  (defmacro make-lexer-actions (definitions standalone-macros)
    `(make-lexer-actions-list (list ,@(mapcar #'(lambda (definition)
                                                  `(list ,(car definition)
                                                         ,(parse-definition (cadr definition))))
                                              definitions)
                                    ,@(mapcar #'(lambda (name)
                                                  `(list ,(format nil "\\\\~a(?![\\w-])" name)
                                                         ((name) (list ',(string-upcase name) name))))
                                              standalone-macros))))
) ; EVAL-WHEN

(defparameter *actions*
  (make-lexer-actions (("[\\n]+" :blank)
                       ("%.*" :blank)
                       ("\\\\begincom{([\\w-]+)}" ((name) (list 'begincom name)))
                       ("\\\\endcom(?![\\w-])" endcom)
                       ("\\\\ftype{([\\w -]+)}" ((name) (list 'ftype name)))
                       ("\\\\label ([\\w :-]+)" ((name) (list 'label name)))
                       ("\\\\typeref{(\\w+)}" ((name) (list 'typeref name)))
                       ("\\\\term{([\\w ]+)}" ((name) (list 'term name)))
                       ("\\\\issue{([\\w :-]+)}" ((name) (list 'issue name)))
                       ("\\\\endissue{([\\w :-]+)}" ((name) (list 'endissue name)))
                       ("\\$([^$]+)\\$" ((content) (list 'math-section content)))
                       ("\\\\Seefun{([\\w -]+)}" ((name) (list 'seefun name)))
                       ;; \Deftype{array}{\ttbrac{\curly{element-type | \misc{*}} \brac{dimension-spec}}}
                       ("\\\\Deftype{([\\w-]+)}" ((name) (list 'deftpe name)))
                       ("\\\\auxbnf{([\\w -]+)}" ((name) (list 'auxbnf name)))
                       ("{" open-brace)
                       ("}" close-brace)
                       ("([\\w .,_|*-])" ((ch) (list 'character ch))))
                      ("ttbrac" "curly" "misc" "brac")))

(defun make-stream-spec-lexer (input-stream)
  (let ((lexer-actions *actions*)
        (current-line nil)
        (current-position 0)
        (input-finish nil))
    #'(lambda ()
        (labels ((read-next-line ()
                   (unless input-finish
                     (setq current-line (read-line input-stream nil nil))
                     (incf *current-line-num*)
                     (setq current-position 0)
                     (cond (current-line
                            :blank)
                           (t
                            (setq input-finish t)
                            nil))))

                 (read-code ()
                   (loop
                      with longest-match-length = 0
                      with longest-match-exprs = nil
                      with longest-match-action = nil
                      for (regex action) in lexer-actions                      
                      do (multiple-value-bind (result exprs)
                             (cl-ppcre:scan-to-strings regex current-line :start current-position)
                           (when (and result
                                      (> (length result) longest-match-length))
                             (setq longest-match-length (length result))
                             (setq longest-match-exprs exprs)
                             (setq longest-match-action action)))
                      finally (cond ((plusp longest-match-length)
                                     (incf current-position longest-match-length)
                                     (return (apply longest-match-action (coerce longest-match-exprs 'list))))
                                    (t
                                     (signal-parse-error "Syntax error"
                                                         current-position
                                                         current-line
                                                         current-position)))))

                 (parse-token ()
                   (cond ((null current-line)
                          (read-next-line))
                         ((>= current-position (length current-line))
                          (read-next-line))
                         (t
                          (read-code)))))

          (loop
             for token = (parse-token)
             while token
             unless (eq token :blank)
             return (apply #'values token))))))

(defun test ()
  (let ((*current-line-num* 0))
    (with-open-file (in (merge-pathnames #p"dpans/dict-arrays.tex" (asdf:system-source-file :parse-lisp-spec)))
      (let ((lexer (make-stream-spec-lexer in)))
        (loop
           for v = (multiple-value-list (funcall lexer))
           while (car v)
           do (print v))))))
