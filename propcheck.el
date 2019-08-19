;;; propcheck.el --- quickcheck/hypothesis style testing for elisp         -*- lexical-binding: t; -*-

;; Copyright (C) 2019  Wilfred Hughes
;; Version: 0.1
;; Package-Requires: ((emacs "25.1") (dash "2.11.0") (dash-functional "1.2.0"))

;; Author: Wilfred Hughes <me@wilfred.me.uk>
;; Keywords: testing

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Property based testing for Emacs Lisp. Heavily influenced by the
;; wonderful Hypothesis project.

;; References:

;; https://hypothesis.works/articles/how-hypothesis-works/
;; https://hypothesis.readthedocs.io/en/latest/details.html#how-good-is-assume
;; https://github.com/HypothesisWorks/hypothesis/blob/master/guides/internals.rst

;;; Code:

(require 'dash)
(require 'dash-functional)
(eval-when-compile
  (require 'cl))

(defvar propcheck-max-examples 100)

;; Hypothesis-java uses 2000 for maxShrinks. You need to be generating
;; large (e.g. several lists) amounts of data before you can hit this
;; limit.
(defvar propcheck-max-shrinks 200)
(defvar propcheck--shrinks-remaining nil)
(defvar propcheck--allow-replay nil)

(defvar propcheck--seed
  nil
  "The current seed being used to generate values.
This is a global variable so users aren't force to pass it to
generate functions.")

;; The value used to generate sample data. This is a list of bytes,
;; along with an index. When regenerating data, resetting the index to
;; 0 and calling the same generate functions will produce the same
;; values.
;;
;; Hypothesis calls this 'TestData'.
(defstruct
    (propcheck-seed
     :named
     (:constructor propcheck-seed
                   (&optional
                    (bytes nil)
                    (i 0)
                    (intervals nil))))
  bytes
  i
  intervals)

(defun propcheck--draw-bytes (seed num-bytes)
  "Get NUM-BYTES of random data from SEED, generating if necessary.
This function modifies SEED and returns the generated bytes."
  ;; Don't draw more bytes than the original seed if we're shrinking.
  (when (propcheck--shrinking-p)
    (when (>=
           (propcheck-seed-i seed)
           (length (propcheck-seed-bytes seed)))
      (throw 'propcheck--overrun t)))

  (propcheck--sanity-check seed)
  (let* ((i (propcheck-seed-i seed))
         (bytes (propcheck-seed-bytes seed))
         (new-i (+ i num-bytes)))
    ;; Update i to record our position in the bytes.
    (setf (propcheck-seed-i seed) new-i)

    ;; Record the intervals of bytes generated.
    (push (list i new-i) (propcheck-seed-intervals seed))

    (if (<= new-i (length bytes))
        ;; SEED already has sufficient bytes, just return the
        ;; previously generated bytes.
        (->> (propcheck-seed-bytes seed)
             (-drop i)
             (-take num-bytes))

      ;; We're currently generating data, add it to the existing
      ;; bytes.
      (let (rand-bytes)
        (dotimes (_ num-bytes)
          (push (random 255) rand-bytes))
        (setf (propcheck-seed-bytes seed) (-concat bytes rand-bytes))
        rand-bytes))))

(defun propcheck--shrinking-p ()
  "Are we currently shrinking after finding a seed that gives a
counterexample?"
  (or propcheck--shrinks-remaining propcheck--allow-replay))

(defun propcheck--debug (&rest _)
  "Debugging helper function"
  ;; Deliberately don't do anything with arguments. Instead, use M-x
  ;; trace-function to see values passed to this function when also
  ;; tracing shrinking logic.
  )

(defun propcheck--seek-start (seed)
  "Return a copy of SEED with i set to the beginning."
  (let ((i (propcheck-seed-i seed))
        (bytes (propcheck-seed-bytes seed))
        (intervals (propcheck-seed-intervals seed)))
    (propcheck--debug "remaining" propcheck--shrinks-remaining)
    (propcheck-seed
     (-take i bytes)
     0
     intervals)))

(defun propcheck--no-intervals (seed)
  "Return a copy of SEED with no intervals"
  (let ((i (propcheck-seed-i seed))
        (bytes (propcheck-seed-bytes seed)))
    (propcheck-seed
     bytes
     i
     nil)))

(defun propcheck--sanity-check (seed)
  (unless seed
    (error "seed must not be nil"))
  (unless (propcheck--shrinking-p)
    (unless (=
             (propcheck-seed-i seed)
             (length (propcheck-seed-bytes seed)))
      (error "Data should be growing when finding counterexamples"))))

;;; Generators

;; These functions generate a random value, updating `propcheck--seed'.
;; They have two important invariants:
;;
;; * Smaller seeds should produce smaller inputs
;; * Smaller seeds should not consume more bytes than larger seeds

;; TODO: `propcheck--seed' should be public, so users can define their
;; own generators.

(defun propcheck-generate-bool ()
  (let ((rand-byte (car (propcheck--draw-bytes propcheck--seed 1))))
    (not (zerop (logand rand-byte 1)))))

(defun propcheck-generate-integer ()
  (let ((sign (car (propcheck--draw-bytes propcheck--seed 1))))
    ;; 50% chance of negative numbers.
    (if (<= sign 128)
        (propcheck--generate-positive-integer)
      (1-
       (- (propcheck--generate-positive-integer))))))

(defun propcheck--generate-positive-integer ()
  (let* ((bits-in-integers (round (log most-positive-fixnum 2)))
         (bytes-needed (ceiling (/ bits-in-integers 8.0)))
         (high-bits-needed (- bits-in-integers
                              (* (1- bytes-needed) 8)))
         (rand-bytes (propcheck--draw-bytes propcheck--seed bytes-needed))
         (result 0))
    (--each-indexed rand-bytes
      ;; Avoid overflow for the bits in the highest byte.
      (when (zerop it-index)
        (setq it (lsh it (- high-bits-needed 8))))

      (setq result
            (+ (* result 256)
               it)))
    result))

(defun propcheck-generate-ascii-char ()
  "Generate a number that's an ASCII char.
Note that elisp does not have a separate character type."
  ;; between 32 and 126
  (let* ((rand-bytes (propcheck--draw-bytes propcheck--seed 1))
         (byte (car rand-bytes))
         (min-ascii 32)
         (max-ascii 126)
         (ascii-range (- max-ascii min-ascii)))
    (+ min-ascii (mod byte ascii-range))))

;; TODO: circular lists, improprer lists/trees.
(defun propcheck-generate-proper-list (item-generator)
  "Generate a list whose items are drawn from ITEM-GENERATOR."
  (let ((result nil))
    ;; Make the list bigger most of the time. 50 is the threshold used
    ;; in ListStrategy.java in hypothesis-java.
    ;; See utils.py/more in Hypothesis for a smarter approach.
    (while (> (car (propcheck--draw-bytes propcheck--seed 1)) 50)
      (push (funcall item-generator) result))
    result))

(defun propcheck-generate-vector (item-generator)
  "Generate a vector whose items are drawn from ITEM-GENERATOR."
  (apply #'vector
         (propcheck-generate-proper-list item-generator)))

(defun propcheck-generate-string ()
  "Generate a string."
  (let ((chars nil))
    ;; Dumb: 75% chance of making the string bigger on each draw.
    ;; TODO: see what hypothesis does
    ;; TODO: multibyte support, key sequence support
    (while (>= (car (propcheck--draw-bytes propcheck--seed 1)) 64)
      (push
       (propcheck-generate-ascii-char)
       chars))
    (concat chars)))

(defun propcheck-should (valid-p)
  (propcheck--debug "valid" valid-p)
  (unless valid-p
    (throw 'propcheck--counterexample
           propcheck--seed)))

(defun propcheck--funcall-with-seed (fun seed)
  "Call FUN with SEED used to generate inputs.
If a counterexample is found, return the final seed."
  (let ((propcheck--seed
         ;; Discard the interval data before calling FUN, so we can
         ;; see if it uses different intervals in this run.
         (propcheck--no-intervals seed)))
    (catch 'propcheck--counterexample
      (catch 'propcheck--overrun
        (funcall fun))
      nil)))

(defun propcheck--find-counterexample (fun)
  "Call FUN until it finds a counterexample.

Returns the seed that produced the counterexample, or
nil if no counterexamples were found after
`propcheck-max-examples' attempts."
  (catch 'found
    (dotimes (_ propcheck-max-examples)
      ;; Generate a fresh seed and try the function.
      (let ((seed (propcheck--funcall-with-seed fun (propcheck-seed))))
        (when seed
          (throw 'found (propcheck--seek-start seed)))))))

(defun propcheck--list-< (x y)
  "Return t if X is less than Y, using a lexicographic ordering.
E.g. we consider (1 3) to be less than (2 2).

Assumes X and Y are the same length."
  (let ((result nil))
    (catch 'done
      (dotimes (i (length x))
        (let ((x-item (nth i x))
              (y-item (nth i y)))
          ;; List is definitely less, the most significant number is
          ;; less.
          (when (< x-item y-item)
            (setq result t)
            (throw 'done nil))
          ;; List is definitely greater, the most significant number
          ;; is greater.
          (when (> x-item y-item)
            (throw 'done nil))
          ;; Otherwise the two numbers are equal, carry on.
          )))
    result))

(defun propcheck--swap-intervals (seed i j)
  "Swap the bytes at interval I with inteval J in SEED,
if interval J is less than I.

Assumes I < J."
  (-let* ((bytes (propcheck-seed-bytes seed))
          (intervals (reverse (propcheck-seed-intervals seed)))
          ((i-start i-end) (nth i intervals))
          ((j-start j-end) (nth j intervals))
          (i-bytes (-slice bytes i-start i-end))
          (j-bytes (-slice bytes j-start j-end)))
    (when (and
           (= (length i-bytes) (length j-bytes))
           (propcheck--list-< j-bytes i-bytes))
      (dotimes (index (- i-end i-start))
        ;; Copy a byte from J to I.
        (setq seed
              (propcheck--set-byte
               seed
               (+ i-start index)
               (nth (+ j-start index) bytes)))
        ;; Write the old byte value of I into J.
        (setq seed
              (propcheck--set-byte
               seed
               (+ j-start index)
               (nth index i-bytes))))
      seed)))

(defun propcheck--shrink-swapping-intervals (test-fn seed)
  "Attempt to shrink SEED by reordering intervals and calling TEST-FN."
  (let ((i 0)
        (j 0)
        (changed t))
    ;; Keep going until we run out of shrinks, or we stop finding
    ;; intervals that we can swap.
    (catch 'out-of-shrinks
      (while changed
        (setq changed nil)
        (setq i 0)

        ;; The seed might shrink during iteration, so keep checking
        ;; the length.
        (while (< i (1- (length (propcheck-seed-intervals seed))))
          (setq j (1+ i))
          (while (< j (length (propcheck-seed-intervals seed)))
            (let ((shrunk-seed (propcheck--swap-intervals seed i j))
                  new-seed)
              (when shrunk-seed
                (setq new-seed
                      (propcheck--funcall-with-seed test-fn shrunk-seed))
                (when new-seed
                  (setq changed t)
                  (setq seed (propcheck--seek-start new-seed)))

                (cl-decf propcheck--shrinks-remaining)
                (unless (> propcheck--shrinks-remaining 0)
                  (throw 'out-of-shrinks t))))
            (cl-incf j))

          (cl-incf i)))))
  seed)

(defun propcheck--shrink-interval-by (test-fn shrink-fn seed)
  "Attempt to shrink SEED by calling TEST-FN with smaller values.
Reduce the size of SEED by applying SHRINK-FN."
  (let ((i 0)
        (changed t))
    ;; Keep going until we run out of shrinks, or we stop finding
    ;; bytes that we can shrink.
    (catch 'out-of-shrinks
      (while changed
        (setq changed nil)
        (setq i 0)

        ;; The seed might shrink during iteration, so keep checking
        ;; the length.
        (while (< i (length (propcheck-seed-intervals seed)))
          (let ((shrunk-seed (funcall shrink-fn seed i))
                new-seed)
            (when shrunk-seed
              (setq new-seed
                    (propcheck--funcall-with-seed test-fn shrunk-seed))
              (when new-seed
                (setq changed t)
                (setq seed (propcheck--seek-start new-seed)))

              (cl-decf propcheck--shrinks-remaining)
              (unless (> propcheck--shrinks-remaining 0)
                (throw 'out-of-shrinks t))))

          (cl-incf i)))))
  seed)

(defun propcheck--shrink-byte-by (test-fn shrink-fn seed)
  "Attempt to shrink SEED by calling TEST-FN with smaller values.
Reduce the size of SEED by applying SHRINK-FN."
  (let ((i 0)
        (changed t))
    ;; Keep going until we run out of shrinks, or we stop finding
    ;; bytes that we can shrink.
    (catch 'out-of-shrinks
      (while changed
        (setq changed nil)
        (setq i 0)

        ;; The seed might shrink during iteration, so keep checking
        ;; the length.
        (while (< i (length (propcheck-seed-bytes seed)))
          (let ((shrunk-seed (funcall shrink-fn seed i))
                new-seed)
            (when shrunk-seed
              (setq new-seed
                    (propcheck--funcall-with-seed test-fn shrunk-seed))
              (when new-seed
                (setq changed t)
                (setq seed (propcheck--seek-start new-seed)))

              (cl-decf propcheck--shrinks-remaining)
              (unless (> propcheck--shrinks-remaining 0)
                (throw 'out-of-shrinks t))))

          (cl-incf i)))))
  seed)

(defun propcheck--set-byte (seed i value)
  "Return a copy of SEED with byte I set to VALUE."
  (let ((bytes (propcheck-seed-bytes seed))
        (intervals (propcheck-seed-intervals seed)))
    (propcheck-seed
     (-replace-at i value bytes)
     (propcheck-seed-i seed)
     intervals)))

(defun propcheck--zero-byte (seed i)
  "Set byte at I in SEED to zero if it isn't already."
  (let* ((bytes (propcheck-seed-bytes seed))
         (byte (nth i bytes)))
    (unless (zerop byte)
      (propcheck--set-byte seed i 0))))

(defun propcheck--subtract-byte (seed i amount)
  "subtract AMOUNT at I in SEED."
  (let* ((bytes (propcheck-seed-bytes seed))
         (byte (nth i bytes)))
    (when (> byte amount)
      (propcheck--set-byte seed i (- byte amount)))))

(defun propcheck--zero-interval (seed n)
  "Set interval N in SEED to zero. Returns a copy of SEED."
  (-let* ((seed-bytes (propcheck-seed-bytes seed))
          ((interval-start interval-end)
           (nth n (reverse (propcheck-seed-intervals seed))))
          (interval-bytes
           (-slice seed-bytes interval-start interval-end)))
    (unless (-all-p #'zerop interval-bytes)
      (dotimes (i (- interval-end interval-start))
        (setq seed
              (propcheck--set-byte seed (+ interval-start i) 0)))
      seed)))

(defun propcheck--shift-right-interval (seed n amount)
  "Shift right by AMOUNT in interval N in SEED.
Returns a copy of SEED.
Assumes AMOUNT is not greater than 8."
  (-let* ((seed-bytes (propcheck-seed-bytes seed))
          ((interval-start interval-end)
           (nth n (reverse (propcheck-seed-intervals seed))))
          (interval-bytes
           (-slice seed-bytes interval-start interval-end))
          (new-bytes nil)
          (carry 0))
    (dolist (byte interval-bytes)
      ;; Given byte 0xN, we build 2 byte number 0xN0,
      ;; shift to produce 0xPQ, then P is our new byte and Q is
      ;; the carry.
      (let* ((padded-byte (lsh byte 8)))
        ;; Do the shift.
        (setq padded-byte (lsh padded-byte (- amount)))
        ;; Extract the new byte and new carry.
        (setq byte (+ (logand (lsh padded-byte -8) 255)
                      carry))
        (setq carry (logand padded-byte 255))
        (push byte new-bytes)))

    (-each-indexed (nreverse new-bytes)
      (lambda (i byte)
        (setq seed
              (propcheck--set-byte seed (+ interval-start i) byte))))
    seed))

(defun propcheck--shrink-counterexample (fun seed shrinks)
  "Call FUN up to SHRINKS times, to find a smaller version of SEED that still
fails."
  (let* ((propcheck--shrinks-remaining shrinks))
    (->> seed
         (propcheck--shrink-interval-by fun #'propcheck--zero-interval)
         (propcheck--shrink-byte-by fun #'propcheck--zero-byte)
         (propcheck--shrink-swapping-intervals fun)
         (propcheck--shrink-interval-by fun (-rpartial #'propcheck--shift-right-interval 1))
         (propcheck--shrink-byte-by fun (-rpartial #'propcheck--subtract-byte 10))
         (propcheck--shrink-byte-by fun (-rpartial #'propcheck--subtract-byte 1)))))

(defun propcheck--find-small-counterexample (fun)
  (let ((seed
         (propcheck--find-counterexample fun)))
    (when seed
      (propcheck--shrink-counterexample fun seed propcheck-max-shrinks))))

(provide 'propcheck)
;;; propcheck.el ends here
