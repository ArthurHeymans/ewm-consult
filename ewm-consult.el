;;; ewm-consult.el --- Consult integration for EWM buffers -*- lexical-binding: t -*-

;; Copyright (C) 2026
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Optional completion integration for application-visiting EWM buffers.
;;
;; Load this package alongside EWM. Once loaded, it tracks `ewm-mode' state via
;; `ewm-mode-hook' and enables/disables integration automatically.

;;; Code:

(require 'seq)
(require 'subr-x)

(defgroup ewm-consult nil
  "Consult integration for EWM."
  :group 'ewm)

(declare-function consult--buffer-state "consult")
(declare-function consult--buffer-query "consult")
(declare-function consult--buffer-pair "consult")

(defvar consult-buffer-sources)
(defvar consult-source-buffer)
(defvar consult--source-buffer)
(defvar ewm-surface-id)
(defvar ewm-mode)

(defcustom ewm-consult-annotate-application-buffers t
  "Whether to annotate application-visiting buffers in buffer completion.
When non-nil, EWM Consult integration advises `internal-complete-buffer' and
adds \"Application\" annotation for buffers visiting compositor surfaces."
  :type 'boolean
  :group 'ewm-consult)

(defcustom ewm-consult-separate-application-source t
  "Whether to add a separate Consult source for application-visiting buffers.
When non-nil and Consult is loaded, EWM Consult integration adds an
\"Application\" source and excludes app buffers from Consult's default
Buffer source."
  :type 'boolean
  :group 'ewm-consult)

(defvar ewm-consult--setup-done nil
  "Whether Consult integration has been applied.")

(defvar ewm-consult--wanted nil
  "Whether Consult integration should be active while `ewm-mode' is enabled.")

(defvar ewm-consult--original-buffer-predicate nil
  "Original buffer predicate from Consult's default Buffer source.")

(defvar ewm-consult--source-buffer-symbol nil
  "Consult variable symbol used for the default Buffer source plist.")

(defvar ewm-consult--original-buffer-source nil
  "Original Consult Buffer source plist before EWM Consult patches it.")

(defvar ewm-consult--source-application
  (list :name "Application"
        :narrow ?a
        :category 'buffer
        :face 'consult-buffer
        :history 'buffer-name-history
        :state #'consult--buffer-state
        :items (lambda ()
                 (mapcar #'buffer-name
                         (seq-filter #'ewm-consult-application-visiting-buffer-p
                                     (buffer-list)))))
  "Consult source for application-visiting buffers.")

(defun ewm-consult-application-visiting-buffer-p (&optional buffer)
  "Return non-nil if BUFFER (or current buffer) is visiting an application."
  (buffer-local-value 'ewm-surface-id (or buffer (current-buffer))))

(defun ewm-consult--annotate-buffer (buffer-name)
  "Return completion annotation for BUFFER-NAME."
  (when-let ((buf (get-buffer buffer-name)))
    (when (ewm-consult-application-visiting-buffer-p buf)
      " Application")))

(defun ewm-consult--internal-complete-buffer-advice (orig-fun string predicate flag)
  "Add EWM annotations to metadata from `internal-complete-buffer'."
  (if (eq flag 'metadata)
      (let ((metadata (funcall orig-fun string predicate flag)))
        (if (and metadata (listp metadata) (eq (car metadata) 'metadata))
            `(metadata
              ,@(cdr metadata)
              (annotation-function . ewm-consult--annotate-buffer))
          `(metadata
            (category . buffer)
            (annotation-function . ewm-consult--annotate-buffer))))
    (funcall orig-fun string predicate flag)))

(defun ewm-consult--buffer-predicate-wrapper (buffer)
  "Exclude application-visiting buffers while preserving existing predicate."
  (and (if ewm-consult--original-buffer-predicate
           (funcall ewm-consult--original-buffer-predicate buffer)
         t)
       (not (ewm-consult-application-visiting-buffer-p buffer))))

(defun ewm-consult--buffer-items ()
  "Return Buffer source candidates with EWM app buffers removed."
  (consult--buffer-query :sort 'visibility
                         :as #'consult--buffer-pair
                         :predicate #'ewm-consult--buffer-predicate-wrapper))

(defun ewm-consult--setup-impl ()
  "Apply Consult integration when requested."
  (when (and ewm-consult--wanted (not ewm-consult--setup-done))
    (setq ewm-consult--setup-done t)
    (add-to-list 'consult-buffer-sources 'ewm-consult--source-application)
    (setq ewm-consult--source-buffer-symbol
          (cond
           ((boundp 'consult-source-buffer) 'consult-source-buffer)
           ((boundp 'consult--source-buffer) 'consult--source-buffer)))
    (when ewm-consult--source-buffer-symbol
      (let ((source-val (symbol-value ewm-consult--source-buffer-symbol)))
        (when (plistp source-val)
          (setq ewm-consult--original-buffer-source source-val)
          (setq ewm-consult--original-buffer-predicate
                (plist-get source-val :predicate))
          (set ewm-consult--source-buffer-symbol
               (let ((patched (plist-put source-val
                                         :predicate #'ewm-consult--buffer-predicate-wrapper)))
                 (plist-put patched :items #'ewm-consult--buffer-items))))))))

(defun ewm-consult--setup ()
  "Enable Consult integration when configured."
  (setq ewm-consult--wanted t)
  (if (featurep 'consult)
      (ewm-consult--setup-impl)
    (with-eval-after-load 'consult
      (ewm-consult--setup-impl))))

(defun ewm-consult--teardown ()
  "Disable Consult integration."
  (setq ewm-consult--wanted nil)
  (when ewm-consult--setup-done
    (setq ewm-consult--setup-done nil)
    (when (boundp 'consult-buffer-sources)
      (setq consult-buffer-sources
            (delq 'ewm-consult--source-application consult-buffer-sources)))
    (when ewm-consult--source-buffer-symbol
      (when (plistp ewm-consult--original-buffer-source)
        (set ewm-consult--source-buffer-symbol ewm-consult--original-buffer-source)))
    (setq ewm-consult--original-buffer-source nil)
    (setq ewm-consult--source-buffer-symbol nil)
    (setq ewm-consult--original-buffer-predicate nil)))

(defun ewm-consult--mode-enable ()
  "Enable completion integrations configured for EWM."
  (when ewm-consult-annotate-application-buffers
    (advice-add 'internal-complete-buffer
                :around
                #'ewm-consult--internal-complete-buffer-advice))
  (when ewm-consult-separate-application-source
    (ewm-consult--setup)))

(defun ewm-consult--mode-disable ()
  "Disable completion integrations configured for EWM."
  (advice-remove 'internal-complete-buffer #'ewm-consult--internal-complete-buffer-advice)
  (ewm-consult--teardown))

(defun ewm-consult--sync-with-ewm-mode ()
  "Synchronize integration state with `ewm-mode'."
  (if (bound-and-true-p ewm-mode)
      (ewm-consult--mode-enable)
    (ewm-consult--mode-disable)))

;;;###autoload
(defun ewm-consult--install-mode-hook ()
  "Install hook to track `ewm-mode' toggles."
  (add-hook 'ewm-mode-hook #'ewm-consult--sync-with-ewm-mode)
  ;; If EWM is already active, apply integration immediately.
  (when (bound-and-true-p ewm-mode)
    (ewm-consult--mode-enable)))

;;;###autoload
(with-eval-after-load 'ewm
  (ewm-consult--install-mode-hook))

(provide 'ewm-consult)
;;; ewm-consult.el ends here
