;;;; compiler-syntax.scm - compiler syntax used internally
;
; Copyright (c) 2009, The Chicken Team
; All rights reserved.
;
; Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following
; conditions are met:
;
;   Redistributions of source code must retain the above copyright notice, this list of conditions and the following
;     disclaimer. 
;   Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following
;     disclaimer in the documentation and/or other materials provided with the distribution. 
;   Neither the name of the author nor the names of its contributors may be used to endorse or promote
;     products derived from this software without specific prior written permission. 
;
; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS
; OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
; AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR
; CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
; CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
; SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
; THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
; OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
; POSSIBILITY OF SUCH DAMAGE.


(declare 
  (unit compiler-syntax) )


(include "compiler-namespace")
(include "tweaks.scm")


;;; Compiler macros (that operate in the expansion phase)

(define compiler-syntax-statistics '())

(set! ##sys#compiler-syntax-hook
  (lambda (name result)
    (let ((a (alist-ref name compiler-syntax-statistics eq? 0)))
      (set! compiler-syntax-statistics
	(alist-update! name (add1 a) compiler-syntax-statistics)))))

(define (r-c-s names transformer #!optional (se '()))
  (let ((t (cons (##sys#er-transformer transformer) se)))
    (for-each
     (lambda (name)
       (##sys#put! name '##compiler#compiler-syntax t) )
     (if (symbol? names) (list names) names) ) ) )

(define-syntax define-internal-compiler-syntax
  (syntax-rules ()
    ((_ (names . llist) (se ...) . body)
     (r-c-s 
      'names (lambda llist . body) 
      `((se . ,(##sys#primitive-alias 'se)) ...)))))

(define-internal-compiler-syntax ((for-each ##sys#for-each #%for-each) x r c)
  (pair?)
  (let ((%let (r 'let))
	(%if (r 'if))
	(%loop (r 'loop))
	(%begin (r 'begin))
	(%and (r 'and))
	(%pair? (r 'pair?))
	(%lambda (r 'lambda))
	(lsts (cddr x)))
    (if (and (memq 'for-each standard-bindings) ; we have to check this because the db (and thus 
	     (> (length+ x) 2)			 ; intrinsic marks) isn't set up yet
	     (or (and (pair? (cadr x))
		      (c %lambda (caadr x)))
		 (symbol? (cadr x))))
	(let ((vars (map (lambda _ (gensym)) lsts)))
	  `(,%let ,%loop ,(map list vars lsts)
		  (,%if (,%and ,@(map (lambda (v) `(,%pair? ,v)) vars))
			(,%begin
			 ((,%begin ,(cadr x))
			  ,@(map (lambda (v) `(##sys#slot ,v 0)) vars))
			 (##core#app 
			  ,%loop
			  ,@(map (lambda (v) `(##sys#slot ,v 1)) vars) ) ))))
	x)))

(define-internal-compiler-syntax ((map ##sys#map #%map) x r c)
  (pair?)
  (let ((%let (r 'let))
	(%if (r 'if))
	(%loop (r 'loop))
	(%res (r 'res))
	(%cons (r 'cons))
	(%set! (r 'set!))
	(%result (r 'result))
	(%node (r 'node))
	(%quote (r 'quote))
	(%begin (r 'begin))
	(%lambda (r 'lambda))
	(%and (r 'and))
	(%pair? (r 'pair?))
	(lsts (cddr x)))
    (if (and (memq 'map standard-bindings) ; s.a.
	     (> (length+ x) 2)
	     (or (and (pair? (cadr x))
		      (c %lambda (caadr x)))
		 (symbol? (cadr x))))
	(let ((vars (map (lambda _ (gensym)) lsts)))
	  `(,%let ((,%result (,%quote ()))
		   (,%node #f))
		  (,%let ,%loop ,(map list vars lsts)
		       (,%if (,%and ,@(map (lambda (v) `(,%pair? ,v)) vars))
			     (,%let ((,%res
				      (,%cons
				       ((,%begin ,(cadr x))
					,@(map (lambda (v) `(##sys#slot ,v 0)) vars))
				       (,%quote ()))))
				    (,%if ,%node
					  (##sys#setslot ,%node 1 ,%res)
					  (,%set! ,%result ,%res))
				    (,%set! ,%node ,%res)
				    (,%loop
				     ,@(map (lambda (v) `(##sys#slot ,v 1)) vars)))
			     ,%result))))
	x)))

(define-internal-compiler-syntax ((o #%o) x r c) ()
  (if (and (fx> (length x) 1)
	   (memq 'o extended-bindings) ) ; s.a.
      (let ((%tmp (r 'tmp)))
	`(,(r 'lambda) (,%tmp) ,(fold-right list %tmp (cdr x))))
      x))

(define-internal-compiler-syntax ((sprintf #%sprintf format #%format) x r c)
  (display write fprintf number->string write-char open-output-string get-output-string)
  (let* ((out (gensym 'out))
	 (code (compile-format-string 
		(if (memq (car x) '(sprintf #%sprintf))
		    'sprintf
		    'format)
		out 
		x
		(cdr x)
		r c)))
    (if code
	`(,(r 'let) ((,out (,(r 'open-output-string))))
	  ,code
	  (,(r 'get-output-string) ,out))
	x)))

(define-internal-compiler-syntax ((fprintf #%fprintf) x r c) 
  (display write fprintf number->string write-char open-output-string get-output-string)
  (if (>= (length x) 3)
      (let ((code (compile-format-string 
		   'fprintf (cadr x) 
		   x (cddr x)
		   r c)))
	(or code x))
      x))

(define-internal-compiler-syntax ((printf #%printf) x r c)
  (display write fprintf number->string write-char open-output-string get-output-string)
  (let ((code (compile-format-string 
	       'printf '##sys#standard-output
	       x (cdr x)
	       r c)))
    (or code x)))

(define (compile-format-string func out x args r c)
  (call/cc
   (lambda (return)
     (and (>= (length args) 1)
	  (memq func extended-bindings)	; s.a.
	  (or (string? (car args))
	      (and (list? (car args))
		   (c (r 'quote) (caar args))
		   (string? (cadar args))))
	  (let ((fstr (if (string? (car args)) (car args) (cadar args)))
		(args (cdr args)))
	    (define (fail ret? msg . args)
	      (let ((ln (get-line x)))
		(compiler-warning 
		 'syntax
		 "(~a) in format string ~s~a, ~?" 
		 func fstr 
		 (if ln (sprintf " in line ~a" ln) "")
		 msg args) ) 
	      (when ret? (return #f)))
	    (let ((code '())
		  (index 0)
		  (len (string-length fstr)) 
		  (%display (r 'display))
		  (%write (r 'write))
		  (%write-char (r 'write-char))
		  (%out (r 'out))
		  (%fprintf (r 'fprintf))
		  (%let (r 'let))
		  (%number->string (r 'number->string)))
	      (define (fetch)
		(let ((c (string-ref fstr index)))
		  (set! index (fx+ index 1))
		  c) )
	      (define (next)
		(if (null? args)
		    (fail #t "too few arguments to formatted output procedure")
		    (let ((x (car args)))
		      (set! args (cdr args))
		      x) ) )
	      (define (endchunk chunk)
		(when (pair? chunk)
		  (push 
		   (if (= 1 (length chunk))
		       `(,%write-char ,(car chunk) ,%out)
		       `(,%display ,(reverse-list->string chunk) ,%out)))))
	      (define (push exp)
		(set! code (cons exp code)))
	      (let loop ((chunk '()))
		(cond ((>= index len)
		       (unless (null? args)
			 (fail #f "too many arguments to formatted output procedure"))
		       (endchunk chunk)
		       `(,%let ((,%out ,out))
			       ,@(reverse code)))
		      (else
		       (let ((c (fetch)))
			 (if (eq? c #\~)
			     (let ((dchar (fetch)))
			       (endchunk chunk)
			       (case (char-upcase dchar)
				 ((#\S) (push `(,%write ,(next) ,%out)))
				 ((#\A) (push `(,%display ,(next) ,%out)))
				 ((#\C) (push `(,%write-char ,(next) ,%out)))
				 ((#\B) (push `(,%display (,%number->string ,(next) 2) ,%out)))
				 ((#\O) (push `(,%display (,%number->string ,(next) 8) ,%out)))
				 ((#\X) (push `(,%display (,%number->string ,(next) 16) ,%out)))
				 ((#\!) (push `(##sys#flush-output ,%out)))
				 ((#\?)
				  (let* ([fstr (next)]
					 [lst (next)] )
				    (push `(##sys#apply ,%fprintf ,%out ,fstr ,lst))))
				 ((#\~) (push `(,write-char #\~ ,%out)))
				 ((#\% #\N) (push `(,%write-char #\newline ,%out)))
				 (else
				  (if (char-whitespace? dchar)
				      (let skip ((c (fetch)))
					(if (char-whitespace? c)
					    (skip (fetch))
					    (set! index (sub1 index))))
				      (fail #t "illegal format-string character `~c'" dchar) ) ) )
			       (loop '()) )
			     (loop (cons c chunk)))))))))))))