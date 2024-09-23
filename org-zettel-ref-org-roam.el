;;; org-zettel-ref-org-roam.el --- Org-roam integration for org-zettel-ref -*- lexical-binding: t; -*-

;;; Commentary:

;; This file contains org-roam integration for org-zettel-ref.

;;; Code:

(when (eq org-zettel-ref-mode-type 'org-roam)
  (require 'org-roam))

(defun org-zettel-ref-get-overview-file-org-roam (source-buffer)
  "Get or create an overview file for SOURCE-BUFFER using org-roam API."
  (let* ((source-file (buffer-file-name source-buffer))
         (title (if source-file
                    (format "Overview - %s" (file-name-base source-file))
                  (format "Overview - %s" (buffer-name source-buffer))))
         file-path)
    (message "Debug: Starting org-zettel-ref-get-overview-file for %s" title)
    (condition-case err
        (progn
          (message "Debug: org-roam loaded successfully. Version: %s" (org-roam-version))
          (let ((existing-node (org-roam-node-from-title-or-alias title)))
            (if existing-node
                (progn
                  (setq file-path (org-roam-node-file existing-node))
                  (message "Debug: Existing node found. File path: %s" file-path))
              (message "Debug: No existing node found, creating new one")
              (let* ((id (org-id-new))
                     (slug (org-roam-node-slug (org-roam-node-create :title title)))
                     (new-file (expand-file-name (concat slug ".org") org-roam-directory)))
                (unless (file-exists-p new-file)
                  (with-temp-file new-file
                    (insert (format ":PROPERTIES:
:ID:       %s
:END:
#+title: %s
#+filetags: :overview:

* Overview

This is an overview of the buffer \"%s\".

* Quick Notes

* Marked Text

"
                                    id title (buffer-name source-buffer)))))
                (setq file-path new-file)
                (message "Debug: New node created. File path: %s" file-path)))))
      (error
       (message "Error in org-roam operations: %S" err)
       (setq org-zettel-ref-mode-type 'normal)))
    file-path))



(provide 'org-zettel-ref-org-roam)

;;; org-zettel-ref-org-roam.el ends here