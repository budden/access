(cl:defpackage :access
  (:use :cl :cl-user :iterate)
  (:shadowing-import-from :alexandria #:ensure-list )
  (:shadowing-import-from :anaphora #:awhen #:aif #:it)
  (:export
   ;; utils to make this work
   #:has-reader?
   #:has-writer?
   #:has-slot?
   #:class-of-object
   #:class-direct-slot-names
   #:class-direct-slot-readers
   #:class-direct-slot-writers
   #:class-slot-names
   #:class-slot-readers
   #:class-slot-writers
   #:equalper
   #:plist-val
   #:rem-plist-val
   #:set-plist-val
   #:call-if-applicable
   #:call-applicable-fns

   ;; main stuff
   #:access
   #:accesses
   #:set-access
   #:set-accesses
   #:access-copy
   #:mutate-access
   #:with-access
   #:with-all-slot-accessors
   #:with-access-values
   #:with-all-slot-access-values

   ;; dot syntax stuff
   #:with-dot
   #:enable-dot-syntax
   #:disable-dot-syntax

   ;; arg-list-manip
   #:arg-list-key-value
   #:set-arg-list-key-value
   #:set-arg-list-key-value!
   #:rem-arg-list-key-value
   #:rem-arg-list-key-value!
   #:ensure-arg-list-key-value
   #:ensure-arg-list-key-value!
   ))

(in-package :access)

(defun equalper (x y)
  "compares symbols by equalp symbol-name"
  (flet ((cast (it)
	   (typecase it
	     (symbol (string it))
	     (t it))))
    (or (eql x y)
	(equalp (cast x) (cast y)))))

(defmethod plist-val (id list &key (test #'equalper) (key #'identity))
  "get a value out of a plist based on its key"
  (iter (for (k v) on list by #'cddr)
	(if (funcall test (funcall key k) id)
	    (return v))))

(defmethod rem-plist-val (id list &key (test #'equalper) (key #'identity))
  "removes key & its value from plist returning
   (values plist (list-of-values-removed))"
  (iter
    (for (k v) on list by #'cddr)
    (cond ((funcall test (funcall key k) id)
           (collect v into removed))
          (T (collect k into plist)
             (collect v into plist)))
    (finally (return (values plist removed)))))

(defmethod set-plist-val (new id list &key (test #'equalper) (key #'identity))
  (iter
    (with collected)
    (for (k v) on list by #'cddr)
    (collect k into res)
    (if (funcall test (funcall key k) id)
	(progn (setf collected T)
	       (collect new into res))
	(collect v into res))
    (finally
     (unless collected
       (setf res (list* id new res)))
     (return res))))

(defun %slot-readers (slots)
  (iter (for slot in (ensure-list slots))
	(for reader-name = (or (first (closer-mop::slot-definition-readers slot))
  ;; NB: We should probably check for a reader fn here before assuming
  ;; the slot name is a reader-fn, but I couldnt find a cross platform way
  ;; of doing this
			      (closer-mop:slot-definition-name slot)))
	(collecting reader-name into names)
	;; some valid slot names are not valid function names (see type)
	(collecting (ignore-errors
		      (symbol-function reader-name)) into readers)
	(finally (return (values readers names)))))

(defun %slot-writers (slots)
  (iter (for slot in (ensure-list slots))
	(for sn = (closer-mop::slot-definition-name slot))
	;; effective slots dont have readers or writers
	;; but direct slots do, no idea why, I asked and its in the spec
	(for wn = (or (first (closer-mop::slot-definition-writers slot))
		      `(setf ,sn)))
	(collecting wn into writer-names)
	(collecting sn into slot-names)
	;; some valid slot names are not valid function names (see type)
	(collecting (ignore-errors (fdefinition wn)) into writers)
	(finally (return (values writers writer-names slot-names)))))

(defun class-of-object ( o )
  (typecase o
    (symbol (find-class o))
    (standard-class o)
    (standard-object (class-of o))))

(defun class-direct-slot-readers ( o )
  (awhen (class-of-object o)
    (%slot-readers (closer-mop:class-direct-slots it ))))

(defun class-slot-readers ( o )
  (awhen (class-of-object o)
    (%slot-readers (closer-mop:class-slots it))))

(defun class-direct-slot-writers (o)
  (awhen (class-of-object o)
    (%slot-writers (closer-mop:class-direct-slots it))))

(defun class-slot-writers (o)
  (awhen (class-of-object o)
    (%slot-writers (closer-mop:class-slots it))))

(defun class-direct-slot-names (o)
  (awhen (class-of-object o)
    (mapcar
     #'closer-mop:slot-definition-name
     (closer-mop:class-direct-slots it))))

(defun class-slot-names (o)
  (awhen (class-of-object o)
    (mapcar
     #'closer-mop:slot-definition-name
     (closer-mop:class-slots it))))

(defun has-reader? (o reader-name)
  "For o, does a reader function exist for it"
  (when (and o reader-name)
    (multiple-value-bind (readers names) (class-slot-readers o)
      (iter (for reader in readers)
	    (for name in names)
	    (when (typecase reader-name
		    ((or keyword string) (string-equal (string name) (string reader-name)))
		    (function (eql reader reader-name))
		    (symbol (eql name reader-name))
		    (T (warn "Not sure how to ~S maps to a function" reader-name)))
	      (return (values reader name)))))))

(defun has-writer? (o writer-name)
  "For o, does a writer function exist for it?"
  (when (and o writer-name)
    (multiple-value-bind (writers wns sns) (class-slot-writers o)
      (iter (for writer in writers)
	    (for wn in wns)
	    (for sn in sns)
	    (when (typecase writer-name
		    ((or keyword string)
		       (or (string-equal (string sn) (string writer-name))
			   (string-equal (princ-to-string wn) (string writer-name))))
		    (function (eql writer writer-name))
		    (list
		       (or (equal wn writer-name)
			   ;; setf-form ;; try again with just the slotname
			   (has-writer? o (second writer-name))))
		    (symbol (eql sn writer-name))
		    (T (warn "Not sure how to ~S maps to a function" writer-name)))
	      (return (values writer wn sn)))))))

(defun has-slot? (o slot-name)
  "Does o have a slot names slot-name"
  (let ((slot-names (class-slot-names o)))
    (typecase slot-name
      ((or keyword string)
	 (member (string slot-name) slot-names :test #'string-equal :key #'string))
      (symbol (member slot-name slot-names)))))

(defun setf-if-applicable (new o fn)
  "If we find a setf function named (setf fn) that can operate on o then call
   that with value new "
  (handler-bind ((undefined-function
		  (lambda (c) (declare (ignore c))
		    (return-from setf-if-applicable nil))))
    (setf fn
	  (typecase fn
	    ((or keyword string symbol) (has-writer? o fn))
	    (function fn)
	    (T (warn "Not sure how to call a ~A" fn) ))))
  (when fn
    ;; complex if/whens instead of ands/ors because a standard generic function
    ;; is a function, but we dont want to call it if not applicable
    (if (typep fn 'standard-generic-function)
	(when (compute-applicable-methods fn (list new o))
	  (values (funcall fn new o) T))
	(when (typep fn 'function)
	  (values (funcall fn new o) T)))))

(defun call-if-applicable (o fn)
  "See if there is a method named fn specialized on o, or a function named fn
   and call it if so"
  (handler-bind ((undefined-function
		  (lambda (c) (declare (ignore c))
		    (return-from call-if-applicable nil))))
    (setf fn
	  (typecase fn
	    ((or keyword string) (has-reader? o fn))
	    (symbol (symbol-function fn))
	    (function fn)
	    (T (warn "Not sure how to call a ~A" fn) ))))
  (when fn
    ;; complex if/whens instead of ands/ors because a standard generic function
    ;; is a function, but we dont want to call it if not applicable
    (handler-case 
	(if (typep fn 'standard-generic-function)
	    (when (compute-applicable-methods fn (list o))
	      (values (funcall fn o) T))
	    (when (typep fn 'function)
	      (values (funcall fn o) T)))
      (unbound-slot (c) (declare (ignore c))))))

(defun call-applicable-fns (o &rest fns)
  "For an object and a list of fn/fn names, call-if-applicable repeatedly"
  (iter (for fn in fns)
	(setf o (call-if-applicable o fn)))
  o)

(defun access (o k &key type (test #'equalper) (key #'identity))
  "Access plists, alists, hashtables and clos objects all through the same interface"
  (if (null type)
      (typecase o
	(list (if (consp (first o))
		  (access o k :type :alist :test test :key key)
		  (access o k :type :plist :test test :key key)))
	(hash-table (access o k :type :hash-table :test test :key key))
	(standard-object (access o k :type :object :test test :key key)))
      (multiple-value-bind (res called) (call-if-applicable o k)
	(if called
	    res
	    (case type
	      (:plist
               (plist-val k o :test test :key key))
	      (:alist
               (cdr (assoc k o :test test :key key)))
	      (:hash-table
               (multiple-value-bind (res found) (gethash k o)
                 (if found
                     res
                     (awhen (ignore-errors (string k))
                       (gethash it o)))))
	      (:object
		  (when (and (has-slot? o k)
			     (slot-boundp o k))
		    (slot-value o k))))))))

(defun set-access (new o k &key type (test #'equalper) (key #'identity))
  "set places in plists, alists, hashtables and clos objects all through the same interface"
  (if (null type)
      (typecase o
        (list (if (consp (first o))
                  (set-access new o k :type :alist :test test :key key)
                  (set-access new o k :type :plist :test test :key key)))
        (hash-table (set-access new o k :type :hash-table :test test :key key))
        (standard-object (set-access new o k :type :object :test test :key key)))
      (multiple-value-bind (res called) (setf-if-applicable new o k)
        (if called
            (values res o)
            (values
             new
             (case type
               (:plist
                (set-plist-val new k o :test test :key key))
               (:alist
                (aif (assoc k o :test test :key key)
                     (progn (setf (cdr it) new) o)
                     (list* (cons k new) o)))
               (:hash-table
                (let ((skey (string k)))
                  (multiple-value-bind (res found) (gethash k o)
                    (declare (ignore res))
                    (multiple-value-bind (sres sfound)
                        (awhen skey (gethash it o))
                      (declare (ignore sres))
                      (cond
                        (found (setf (gethash k o) new))
                        ((or sfound skey) (setf (gethash skey o) new))
                        (T (setf (gethash k o) new)))
                      (if found
                          (setf (gethash k o) new)))
                    ))
                o)
               (:object
                   (when (has-slot? o k)
                     (setf (slot-value o k) new))
                 o)))))))

(define-setf-expander access (place key
                              &environment env
                              &aux (new-val (gensym "NEW-VAL"))
                              (place-store (gensym "PLACE")))
  "This should allow setting places through access"
  (declare (ignore env))
  (values ()   ;; not using temp vars
          ()   ;; not using temp vals
          `(,new-val)
          `(multiple-value-bind (,new-val ,place-store)
            (set-access ,new-val ,place ,key)
            (setf ,place ,place-store)
            ,new-val)
          `(access ,place ,key)))

(defun accesses (o &rest keys)
  "keep accessing keys on resulting objects
   eg: (accesses o k1 k2) => (access (access o k1) k2)"
  (iter (for k in keys)
    (setf o (access o k)))
  o)

(defun set-accesses (new o &rest keys)
  "keep accessing till you get to the end of keys , then store the result of
   setting that field back up the call tree

   returns the new value and the object that was stored there
   (so for a plist / alist you have a ref to the val and the full list)
  "
  (labels ((rec-set (o key more)
             (cond
               (more
                (multiple-value-bind (new new-place-val)
                    (rec-set (access o key) (first more) (rest more))
                  (setf (access o key) new-place-val)
                  (values new o)))
               (T (set-access new o key)))))
    (rec-set o (first keys) (rest keys))))

(define-setf-expander accesses (place &rest keys
                                &environment env
                                &aux (new-val (gensym "NEW-VAL"))
                                (place-store (gensym "PLACE")))
  (declare (ignore env))
  (values ()   ;; not using temp vars
          ()   ;; not using temp vals
          `(,new-val)
          `(multiple-value-bind (,new-val ,place-store)
            (set-accesses ,new-val ,place ,@keys)
            (setf ,place ,place-store)
            ,new-val)
          `(accesses ,place ,@keys)))

(defun mutate-access (o k fn)
  "Mutate the value stored in key k on object o, by passing it through fn"
  (awhen (access o k)
    (setf (access o k) (funcall fn it))))

(defun access-copy (from to keys)
  "Copy the values on 'from' to 'to' for all of the keys listed  "
  (iter (for k in keys)
	(for (k1 k2) = (if (listp k) k (list k k)))
	(setf (access to k2) (access from k1))))

(defmacro with-access ((&rest keys) val-form &body body)
  "Similar to with-accessors except using the access functions"
  (let* ((gval (gensym "val"))
	 (forms
	  (iter (for k in keys)
		(for (k-to k-from) = (if (listp k) k (list k k)))
		(collect `(,k-to (access ,gval ',k-from))))))
    `(let ((,gval ,val-form))
       (declare (ignorable ,gval))
       (symbol-macrolet (,@forms)
	 ,@body
	 ))))

(defun %create-accessor-symbol-list (class)
  "Gets the slots off a class an builds binding like  (local::symbol orig::symbol)
   where local is the current *package* and orig is the original package of the symbol

   used in with-all-slot-accessors"
  (let ((class (etypecase class
		 (symbol (find-class class))
		 (standard-class class))))
    (closer-mop:ensure-finalized class)
    (iter (for slot-name in (class-slot-names class))
      ;; collect bindings of local-symbol to class-slot-name
      (collect (list (intern (symbol-name slot-name))
                     slot-name)))))

(defun %remove-quote-&-or (class-name)
  "remove any quote / ors so that list type-specifications"
  (typecase class-name
    (list
     (case (first class-name)
       (quote (%remove-quote-&-or (second class-name)))
       (or (%remove-quote-&-or (rest class-name)))
       (t class-name)))
    (symbol class-name)))

(defmacro with-access-values (bindings obj &body body)
  "A macro which binds local variables from accessed values on object
   according to bindings

   bindings: (local-symbol-and-access-key
              or (local-symbol access-key)
               ...)
   obj: the thing we are accessing data from
  "
  (flet ((key-for (it)
           (etypecase it
             (symbol `(quote ,it))
             ((or string keyword list) it))))
    (let* ((o (gensym "OBJ"))
           (expanded-bindings
             (iter (for b in (ensure-list bindings))
               (when (first-iteration-p)
                 (collect `(,o ,obj)))
               (typecase b
                 (null)
                 (list (collect `(,(first b) (access ,o ,(key-for (second b))))))
                 (symbol (collect `(,b (access ,o ,(key-for b)))))))))
      `(let* ,expanded-bindings
        ,@body))))

(defun %with-all-slot-helper (data class-name body
                                   &key (with-name 'with-access)
                                   (add-ignorables? nil)
                                   &aux (sdata data))
  "A macro which binds (like with-access) all slot names of a class to a local
   symbolmacro let storing and retrieving using access

   class-name: a symbol or a list of class-names (symbols)
     to make this easier to call we ignore quote and or
     eg: 't1=>t1, (or 't1 't2 ...)=> (t1 t2 ...)
  "
  (setf with-name (%remove-quote-&-or with-name))
  (labels ((typed-form (class-name)
             (let* ((symlist (%create-accessor-symbol-list class-name)))
               `(,with-name ,symlist ,sdata
                 ,@(when add-ignorables?
                     `((declare (ignorable ,@(mapcar #'first symlist)))))
                 ,@body))))
    (setf class-name (%remove-quote-&-or class-name))
    (typecase class-name
      (list
       (setf sdata (gensym "DATA"))
       `(let ((,sdata ,data))
         (etypecase ,sdata
           ,@(iter (for cn in class-name)
               (setf cn (%remove-quote-&-or cn))
               (collect (list cn (typed-form cn)))))))
      (symbol (typed-form class-name)))))

(defmacro with-all-slot-accessors ((data class-name) &body body)
  "A macro which binds (like with-access) all slot names of a class to a local
   symbolmacro let storing and retrieving using access

   class-name: a symbol or a list of class-names (symbols)
     to make this easier to call we ignore quote and or
     eg: 't1=>t1, (or 't1 't2 ...)=> (t1 t2 ...)
  "
  (%with-all-slot-helper data class-name body))

(defmacro with-all-slot-access-values ((obj class) &body body)
  "A macro which binds local variables for each slot value in class
   as by access"
  (%with-all-slot-helper obj class body
    :with-name 'access:with-access-values
    :add-ignorables? t))

;;;; DOT Syntax stuff

(defun translate-dot-sym (sym)
  (let* ((pieces (iter (for piece in (cl-ppcre:split "\\." (string sym)))
		       (collect (intern piece (or (symbol-package sym) *package*)))))
	 (fns (iter (for sym in (rest pieces))
		    (collect `(quote ,sym)))))
    (if (eql 1 (length pieces))
	sym
	`(accesses ,(first pieces) ,@fns))))

(defun dot-translate-walker (form)
  (typecase form
    (cons (cons (dot-translate-walker (car form))
		(dot-translate-walker (cdr form))))
    (symbol (translate-dot-sym form))
    (atom form)))

(defun name-has-dot? (n)
  (cl-ppcre:all-matches "\\." (string n)))

(defun replace-dot-calls (forms)
  (dot-translate-walker forms))

(defmacro with-dot (() &body body)
  `(progn ,@(replace-dot-calls body)))

(defun dot-reader (-stream- char arg)
  "Reads a form and replaces dot calls"
  (declare (ignore arg char))
  (first (replace-dot-calls (list (read -stream-)))))

(defvar *dot-previous-readtables* nil
  "A stack which holds the previous readtables that have been pushed
here by ENABLE-DOT-SYNTAX.")

(defun %enable-dot-syntax ()
  "Internal function used to enable reader syntax and store current
readtable on stack."
  (push *readtable*
        *dot-previous-readtables*)
  (setq *readtable* (copy-readtable))
  (set-dispatch-macro-character #\# #\D #'dot-reader)
  (values))

(defun %disable-dot-syntax ()
  "Internal function used to restore previous readtable." 
  (if *dot-previous-readtables*
    (setq *readtable* (pop *dot-previous-readtables*))
    (setq *readtable* (copy-readtable nil)))
  (values))

(defmacro enable-dot-syntax ()
  "Enable reader syntax."
  `(eval-when (:compile-toplevel :load-toplevel :execute)
    (%enable-dot-syntax)))

(defmacro disable-dot-syntax ()
  "Restore readtable which was active before last call to If there was no such call, the standard
readtable is used."
  `(eval-when (:compile-toplevel :load-toplevel :execute)
    (%disable-dot-syntax)))

