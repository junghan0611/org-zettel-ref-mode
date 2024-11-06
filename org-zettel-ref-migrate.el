;;; org-zettel-ref-migrate.el --- Migration utilities for org-zettel-ref -*- lexical-binding: t; -*-

(require 'org-zettel-ref-db)



;;;###autoload
(defun org-zettel-ref-migrate ()
  "Interactive command to migrate from old database format to new structure."
  (interactive)
  ;; Ask user for confirmation
  (when (yes-or-no-p "This will migrate your old database to the new format. Continue? ")
    (let ((old-data (org-zettel-ref-load-data)))
      (if (not old-data)
          (message "No old database found to migrate.")
        (let ((new-db (org-zettel-ref-migrate-from-old-format--internal old-data)))
          ;; Save the new database
          (org-zettel-ref-db-save new-db)
          (message "Migration completed successfully. New database has been saved."))))))

;; Keep the original function but rename it to indicate it's internal
(defun org-zettel-ref-migrate-from-old-format--internal (old-data)
  "Internal function to migrate from old database format to new structure.
OLD-DATA is the old database data structure."
  (message "Starting migration from old format...")
  
  ;; Create a new database instance
  (let ((new-db (make-org-zettel-ref-db)))
    
    ;; Extract mapping relationships from old data
    (let ((overview-index (cdr (assq 'overview-index old-data))))
      (message "DEBUG: Old overview-index size: %d" (hash-table-count overview-index))
      (message "DEBUG: Old overview-index content:")
      (maphash (lambda (k v) (message "  %s -> %s" k v)) overview-index)
      
      (maphash
       (lambda (ref-path overview-path)
         (message "DEBUG: Processing ref-path: %s" ref-path)
         (message "DEBUG: Processing overview-path: %s" overview-path)
         
         ;; Create and store reference entry
         (let* ((ref-entry (org-zettel-ref-db-create-ref-entry
                           new-db
                           ref-path
                           (file-name-base ref-path)
                           nil  ; author
                           nil)) ; keywords
                (ref-id (org-zettel-ref-ref-entry-id ref-entry)))
           
           (message "DEBUG: Created ref entry with ID: %s" ref-id)
           
           ;; Add reference entry
           (org-zettel-ref-db-add-ref-entry new-db ref-entry)
           
           ;; Create and store overview entry ID (ensure uniqueness)
           (let* ((base-id (format-time-string "%Y%m%dT%H%M%S"))
                  (counter 0)
                  (overview-id base-id))
             
             ;; Ensure overview-id is unique
             (while (gethash overview-id (org-zettel-ref-db-overviews new-db))
               (setq counter (1+ counter)
                     overview-id (format "%s-%03d" base-id counter)))
             
             ;; Create overview entry
             (let ((overview-entry (make-org-zettel-ref-overview-entry
                                  :id overview-id
                                  :ref-id ref-id
                                  :file-path overview-path
                                  :title (file-name-base overview-path)
                                  :created (current-time)
                                  :modified (current-time))))
               
               (message "DEBUG: Created overview entry with ID: %s" overview-id)
               
               ;; Add overview entry
               (org-zettel-ref-db-add-overview-entry new-db overview-entry)
               
               ;; Establish mapping relationship
               (org-zettel-ref-db-add-map new-db ref-id overview-id)))))
       overview-index))
    
    (message "Migration completed.")
    (message "DEBUG: Final refs count: %d" 
             (hash-table-count (org-zettel-ref-db-refs new-db)))
    (message "DEBUG: Final overviews count: %d" 
             (hash-table-count (org-zettel-ref-db-overviews new-db)))
    (message "DEBUG: Final maps count: %d" 
             (hash-table-count (org-zettel-ref-db-map new-db)))
    
    new-db))

(provide 'org-zettel-ref-migrate)
;;; org-zettel-ref-migrate.el ends here 