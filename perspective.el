;;; perspective.el --- switch between named "perspectives" of the editor

;; Copyright (C) 2008-2015 Natalie Weizenbaum <nex342@gmail.com>
;;
;; Licensed under the same terms as Emacs and under the MIT license.

;; Author: Natalie Weizenbaum <nex342@gmail.com>
;; URL: http://github.com/nex3/perspective-el
;; Package-Requires: ((cl-lib "0.5"))
;; Version: 1.12
;; Created: 2008-03-05
;; By: Natalie Weizenbaum <nex342@gmail.com>
;; Keywords: workspace, convenience, frames

;;; Commentary:

;; This package provides tagged workspaces in Emacs, similar to
;; workspaces in windows managers such as Awesome and XMonad (and
;; somewhat similar to multiple desktops in Gnome or Spaces in OS X).

;; perspective.el provides multiple workspaces (or "perspectives") for
;; each Emacs frame.  This makes it easy to work on many separate projects
;; without getting lost in all the buffers.

;; Each perspective is composed of a window configuration and a set of
;; buffers.  Switching to a perspective activates its window
;; configuration, and when in a perspective only its buffers are
;; available by default.

(require 'cl-lib)

;; 'cl' is still required because the use of 'lexical-let'.  'lexical-let' has
;; been deprecated since emacs 24.1, and it should be replaced with true
;; lexical bindings.  For more information, please see
;; https://www.gnu.org/software/emacs/manual/html_node/cl/
;; Obsolete-Lexical-Binding.html
(require 'cl)

(defvar ido-temp-list)

;;; Code:

(defgroup perspective-mode 'nil
  "Customization for Perspective mode"
  :group 'frames)

(defcustom persp-initial-frame-name "main"
  "Name used for the initial perspective when enabling `persp-mode'."
  :type 'string
  :group 'perspective-mode)

(defcustom persp-show-modestring t
  "Determines if `persp-modestring' is shown in the modeline.
If the value is 'header, `persp-modestring' is shown in the
header line instead."
  :group 'perspective-mode
  :type '(choice (const :tag "Off" nil)
                 (const :tag "Modeline" t)
                 (const :tag "Header" 'header)))

(defcustom persp-modestring-dividers '("[" "]" "|")
  "Plist of strings used to created `persp-modestring'.
First string is the start of the modestring, second is the
closing of the mode string, and the last is the divider between
perspectives."
  :group 'perspective-mode
  :type '(list (string :tag "Open")
               (string :tag "Close")
               (string :tag "Divider")))

(defcustom persp-mode-prefix-key (kbd "C-x x")
  "Prefix key to activate perspective-map"
  :group 'perspective-mode
  :set (lambda (sym value)
	 (when (and (bound-and-true-p persp-mode-map)
		    (bound-and-true-p perspective-map))
           (persp-mode-set-prefix-key value))
	 (set-default sym value))
  :type 'key-sequence)

(defcustom persp-switch-wrap t
  "Whether `persp-next' and `persp-prev' should wrap."
  :group 'perspective-mode
  :type 'boolean)

;; This is only available in Emacs >23,
;; so we redefine it here for compatibility.
(unless (fboundp 'with-selected-frame)
  (defmacro with-selected-frame (frame &rest body)
    "Execute the forms in BODY with FRAME as the selected frame.
The value returned is the value of the last form in BODY.
See also `with-temp-buffer'."
    (declare (indent 1) (debug t))
    (let ((old-frame (make-symbol "old-frame"))
          (old-buffer (make-symbol "old-buffer")))
      `(let ((,old-frame (selected-frame))
             (,old-buffer (current-buffer)))
         (unwind-protect
             (progn (select-frame ,frame)
                    ,@body)
           (if (frame-live-p ,old-frame)
               (select-frame ,old-frame))
           (if (buffer-live-p ,old-buffer)
               (set-buffer ,old-buffer)))))))

(cl-defstruct (perspective
               (:conc-name persp-)
               (:constructor make-persp-internal))
  name buffers killed local-variables
  (buffer-history buffer-name-history)
  (window-configuration (current-window-configuration))
  (point-marker (point-marker)))

(defalias 'persp-killed-p 'persp-killed
  "Return whether the perspective CL-X has been killed.")

(defvar persp-interactive-completion-function
  (if ido-mode 'ido-completing-read 'completing-read)
  "The function which is used by perspective.el to interactivly complete user input")

(defvar persp-before-switch-hook nil
  "A hook that's run before `persp-switch'.
Run with the previous perspective as `persp-curr'.")

(defvar persp-switch-hook nil
  "A hook that's run after `persp-switch'.
Run with the newly created perspective as `persp-curr'.")

(defvar persp-mode-hook nil
  "A hook that's run after `persp-mode' has been activated.")

(defvar persp-created-hook nil
  "A hook that's run after a perspective has been created.
Run with the newly created perspective as `persp-curr'.")

(defvar persp-killed-hook nil
  "A hook that's run just before a perspective is destroyed.
Run with the perspective to be destroyed as `persp-curr'.")

(defvar persp-activated-hook nil
  "A hook that's run after a perspective has been activated.
Run with the activated perspective active.")

(defvar persp-mode-map (make-sparse-keymap)
  "Keymap for perspective-mode.")

(define-prefix-command 'perspective-map)
(define-key persp-mode-map persp-mode-prefix-key 'perspective-map)

(define-key perspective-map (kbd "s") 'persp-switch)
(define-key perspective-map (kbd "k") 'persp-remove-buffer)
(define-key perspective-map (kbd "c") 'persp-kill)
(define-key perspective-map (kbd "r") 'persp-rename)
(define-key perspective-map (kbd "a") 'persp-add-buffer)
(define-key perspective-map (kbd "A") 'persp-set-buffer)
(define-key perspective-map (kbd "b") 'persp-switch-to-buffer)
(define-key perspective-map (kbd "i") 'persp-import)
(define-key perspective-map (kbd "n") 'persp-next)
(define-key perspective-map (kbd "<right>") 'persp-next)
(define-key perspective-map (kbd "p") 'persp-prev)
(define-key perspective-map (kbd "<left>") 'persp-prev)
(define-key perspective-map persp-mode-prefix-key 'persp-switch-last)

(defun persp-mode-set-prefix-key (newkey)
  "Set the prefix key to activate persp-mode"
  (substitute-key-definition 'perspective-map nil persp-mode-map)
  (define-key persp-mode-map newkey 'perspective-map))

(defvar persp-protected nil
  "Whether a perspective error should cause persp-mode to be disabled.
Dynamically bound by `persp-protect'.")

(defface persp-selected-face
  '((t (:weight bold :foreground "Blue")))
  "The face used to highlight the current perspective on the modeline.")

(defmacro persp-protect (&rest body)
  "Wrap BODY to disable persp-mode when it errors out.
This prevents the persp-mode from completely breaking Emacs."
  (declare (indent 0))
  (let ((persp-protected t))
    `(condition-case err
         (progn ,@body)
       (persp-error
        (message "Fatal persp-mode error: %S" err)
        (persp-mode -1)))))

(defun persp-error (&rest args)
  "Like `error', but marks it as a persp-specific error.
Used along with `persp-protect' to ensure that persp-mode doesn't
bring down Emacs."
  (if persp-protected
      (signal 'persp-error (list (apply 'format args)))
    (apply 'error args)))

(defun check-persp (persp)
  "Raise an error if PERSP has been killed."
  (cond
   ((not persp)
    (persp-error "Expected perspective, was nil"))
   ((persp-killed-p persp)
    (persp-error "Using killed perspective `%s'" (persp-name persp)))))

(defmacro make-persp (&rest args)
  "Create a new perspective struct and put it in `perspectives-hash'.

ARGS is a list of keyword arguments followed by an optional BODY.
The keyword arguments set the fields of the perspective struct.
If BODY is given, it is executed to set the window configuration
for the perspective."
  (declare (indent defun))
  (let ((keywords))
    (while (keywordp (car args))
      (dotimes (_ 2) (push (pop args) keywords)))
    (setq keywords (reverse keywords))
    `(let ((persp (make-persp-internal ,@keywords)))
       (when (frame-parameter nil 'persp-curr)
         (setf (persp-local-variables persp) (persp-local-variables (frame-parameter nil 'persp-curr))))
       (puthash (persp-name persp) persp (frame-parameter nil 'perspectives-hash))
       (with-perspective (persp-name persp)
         ,(when args
            ;; Body form given
            `(save-excursion ,@args))
         (run-hooks 'persp-created-hook))
       persp)))

(defun persp-save ()
  "Save the current perspective state.
Specifically, save the current window configuration and
perspective-local variables to `persp-curr'"
  (when (frame-parameter nil 'persp-curr)
    (setf (persp-local-variables (frame-parameter nil 'persp-curr))
          (mapcar
           (lambda (c)
             (let ((name (car c)))
               (list name (symbol-value name))))
           (persp-local-variables (frame-parameter nil 'persp-curr))))
    (setf (persp-buffer-history (frame-parameter nil 'persp-curr)) buffer-name-history)
    (setf (persp-window-configuration (frame-parameter nil 'persp-curr)) (current-window-configuration))
    (setf (persp-point-marker (frame-parameter nil 'persp-curr)) (point-marker))))

(defun persp-names ()
  "Return a list of the names of all perspectives, sorted alphabetically."
  (sort
   (cl-loop for name being the hash-keys of (frame-parameter nil 'perspectives-hash)
            collect name)
   'string<))

(defun persp-all-names (&optional not-frame)
  "Return a list of the perspective names for all frames.
Excludes NOT-FRAME, if given."
  (cl-reduce 'union
             (mapcar
              (lambda (frame)
                (unless (equal frame not-frame)
                  (with-selected-frame frame (persp-names))))
              (frame-list))))

(defun persp-prompt (&optional default require-match)
  "Prompt for the name of a perspective.

DEFAULT is a default value for the prompt.

REQUIRE-MATCH can take the same values as in `completing-read'."
  (funcall persp-interactive-completion-function (concat "Perspective name"
                           (if default (concat " (default " default ")") "")
                           ": ")
                   (persp-names)
                   nil require-match nil nil default))

(defmacro with-perspective (name &rest body)
  "Switch to the perspective given by NAME while evaluating BODY."
  (declare (indent 1))
  (let ((old (cl-gensym)))
    `(progn
       (let ((,old (when (frame-parameter nil 'persp-curr) (persp-name (frame-parameter nil 'persp-curr))))
             (last-persp-cache (frame-parameter nil 'persp-last)))
         (unwind-protect
             (progn
               (persp-switch ,name)
               ,@body)
           (when ,old (persp-switch ,old)))
         (set-frame-parameter nil 'persp-last last-persp-cache)))))

(defun persp-new (name)
  "Return a new perspective with name NAME.
The new perspective will start with only an `initial-major-mode'
buffer called \"*scratch* (NAME)\"."
  (make-persp :name name
    (switch-to-buffer (concat "*scratch* (" name ")"))
    (funcall initial-major-mode)
    (delete-other-windows)))

(defun persp-reactivate-buffers (buffers)
  "Raise BUFFERS to the top of the most-recently-selected list.
Returns BUFFERS with all non-living buffers removed.

See also `other-buffer'."
  (cl-loop for buf in (reverse buffers)
           if (not (null (buffer-name buf)))
           collect buf into living-buffers
           and do (switch-to-buffer buf)
           finally return (reverse living-buffers)))

(defun persp-set-local-variables (vars)
  "Set the local variables given in VARS.
VARS should be an alist of variable names to values."
  (dolist (var vars) (apply 'set var)))

(defun persp-intersperse (list interspersed-val)
  "Intersperse a value into a list.
Return a new list made from taking LIST and inserting
INTERSPERSED-VAL between every pair of items.

For example, (persp-intersperse '(1 2 3) 'a) gives '(1 a 2 a 3)."
  (reverse
   (cl-reduce
    (lambda (list el) (if list (cl-list* el interspersed-val list) (list el)))
    list :initial-value nil)))

(defconst persp-mode-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line down-mouse-1] 'persp-mode-line-click)
    map))

(defun persp-mode-line-click (event)
  "Select the clicked perspective.
EVENT is the click event triggering this function call."
  (interactive "e")
  (persp-switch (format "%s" (car (posn-string (event-start event))))))

(defun persp-mode-line ()
  "Use this in the mode-line to show up-to-date value of `persp-modestring'."
  (frame-parameter nil 'persp-modestring))

(defun persp-update-modestring ()
  "Update `persp-modestring' to reflect the current perspectives.
Has no effect when `persp-show-modestring' is nil."
  (when persp-show-modestring
    (let ((open (list (nth 0 persp-modestring-dividers)))
          (close (list (nth 1 persp-modestring-dividers)))
          (sep (nth 2 persp-modestring-dividers)))
      (set-frame-parameter nil 'persp-modestring
           (append open
                   (persp-intersperse (mapcar 'persp-format-name
                                              (persp-names)) sep)
                   close)))))


(defun persp-format-name (name)
  "Format the perspective name given by NAME for display in `persp-modestring'."
  (let ((string-name (format "%s" name)))
    (if (equal name (persp-name (frame-parameter nil 'persp-curr)))
        (propertize string-name 'face 'persp-selected-face)
      (propertize string-name
                  'local-map persp-mode-line-map
                  'mouse-face 'mode-line-highlight))))

(defun persp-get-quick (char &optional prev)
  "Return the name of the first perspective that begins with CHAR.
Perspectives are sorted alphabetically.

PREV can be the name of a perspective.  If it's passed,
this will try to return the perspective alphabetically after PREV.
This is used for cycling between perspectives."
  (persp-get-quick-helper char prev (persp-names)))

(defun persp-get-quick-helper (char prev names)
  (if (null names) nil
    (let ((name (car names)))
      (cond
       ((and (null prev) (eq (string-to-char name) char)) name)
       ((equal name prev)
        (if (and (not (null (cdr names))) (eq (string-to-char (cadr names)) char))
            (cadr names)
          (persp-get-quick char)))
       (t (persp-get-quick-helper char prev (cdr names)))))))

(defun persp-switch-last ()
  "Switch to the perspective accessed before the current one."
  (interactive)
  (unless (frame-parameter nil 'persp-last)
    (error "There is no last perspective"))
  (persp-switch (persp-name (frame-parameter nil 'persp-last))))

(defun persp-switch (name)
  "Switch to the perspective given by NAME.
If it doesn't exist, create a new perspective and switch to that.

Switching to a perspective means that all buffers associated with
that perspective are reactivated (see `persp-reactivate-buffers'),
the perspective's window configuration is restored, and the
perspective's local variables are set."
  (interactive "i")
  (if (null name) (setq name (persp-prompt (and (frame-parameter nil 'persp-last) (persp-name (frame-parameter nil 'persp-last))))))
  (if (and (frame-parameter nil 'persp-curr) (equal name (persp-name (frame-parameter nil 'persp-curr)))) name
    (let ((persp (gethash name (frame-parameter nil 'perspectives-hash))))
      (set-frame-parameter nil 'persp-last (frame-parameter nil 'persp-curr))
      (when (null persp)
        (setq persp (persp-new name)))
      (run-hooks 'persp-before-switch-hook)
      (persp-activate persp)
      name))
  (run-hooks 'persp-switch-hook))

(defun persp-activate (persp)
  "Activate the perspective given by the persp struct PERSP."
  (check-persp persp)
  (persp-save)
  (set-frame-parameter nil 'persp-curr persp)
  (persp-set-local-variables (persp-local-variables persp))
  (persp-reactivate-buffers (persp-buffers persp))
  (setq buffer-name-history (persp-buffer-history persp))
  (set-window-configuration (persp-window-configuration persp))
  (goto-char (persp-point-marker persp))
  (persp-update-modestring)
  (run-hooks 'persp-activated-hook))

(defun persp-switch-quick (char)
  "Switch to the first perspective, alphabetically, that begins with CHAR.

Sets `this-command' (and thus `last-command') to (persp-switch-quick . CHAR).

See `persp-switch', `persp-get-quick'."
  (interactive "c")
  (let ((persp (if (and (consp last-command) (eq (car last-command) this-command))
                   (persp-get-quick char (cdr last-command))
                 (persp-get-quick char))))
    (setq this-command (cons this-command persp))
    (if persp (persp-switch persp)
      (persp-error (concat "No perspective name begins with " (string char))))))

(defun persp-next ()
  "Switch to next perspective (to the right)."
  (interactive)
  (let* ((names (persp-names))
         (pos (cl-position (persp-name (frame-parameter nil 'persp-curr)) names)))
    (cond
     ((null pos) (persp-find-some))
     ((= pos (1- (length names)))
      (if persp-switch-wrap (persp-switch (nth 0 names))))
     (t (persp-switch (nth (1+ pos) names))))))

(defun persp-prev ()
  "Switch to previous perspective (to the left)."
  (interactive)
  (let* ((names (persp-names))
         (pos (cl-position (persp-name (frame-parameter nil 'persp-curr)) names)))
    (cond
     ((null pos) (persp-find-some))
     ((= pos 0)
      (if persp-switch-wrap (persp-switch (nth (1- (length names)) names))))
     (t (persp-switch (nth (1- pos) names))))))

(defun persp-find-some ()
  "Return the name of a valid perspective.

This function tries to return the \"most appropriate\"
perspective to switch to.  It tries:

  * The perspective given by `persp-last'.
  * The main perspective.
  * The first existing perspective, alphabetically.

If none of these perspectives can be found, this function will
create a new main perspective and return \"main\"."
  (cond
   ((frame-parameter nil 'persp-last) (persp-name (frame-parameter nil 'persp-last)))
   ((gethash persp-initial-frame-name (frame-parameter nil 'perspectives-hash)) persp-initial-frame-name)
   ((> (hash-table-count (frame-parameter nil 'perspectives-hash)) 0) (car (persp-names)))
   (t (persp-activate
       (make-persp :name persp-initial-frame-name :buffers (buffer-list)
         :window-configuration (current-window-configuration)
         :point-marker (point-marker)))
      persp-initial-frame-name)))

(defun persp-add-buffer (buffer)
  "Associate BUFFER with the current perspective.

See also `persp-switch' and `persp-remove-buffer'."
  (interactive
   (list
    (let ((read-buffer-function nil))
      (read-buffer "Add buffer to perspective: "))))
  (let ((buffer (get-buffer buffer)))
    (unless (memq buffer (persp-buffers (frame-parameter nil 'persp-curr)))
      (push buffer (persp-buffers (frame-parameter nil 'persp-curr))))))

(defun persp-set-buffer (buffer-name)
  "Associate BUFFER-NAME with the current perspective and remove it from any other."
  (interactive
   (list
    (let ((read-buffer-function nil))
      (read-buffer "Set buffer to perspective: "))))
  (cond ((get-buffer buffer-name)
         (persp-add-buffer buffer-name)
         (cl-loop for other-persp = (persp-buffer-in-other-p (get-buffer buffer-name))
                  while other-persp
                  do (with-perspective (cdr other-persp)
                                       (persp-remove-buffer buffer-name))))
        (t (message "buffer %s doesn't exist" buffer-name))))

(cl-defun persp-buffer-in-other-p (buffer)
  "Returns nil if BUFFER is only in the current perspective.
Otherwise, returns (FRAME . NAME), the frame and name of another
perspective that has the buffer.

Prefers perspectives in the selected frame."
  (cl-loop for frame in (sort (frame-list) (lambda (frame1 frame2) (eq frame2 (selected-frame))))
           do (cl-loop for persp being the hash-values of (frame-parameter frame 'perspectives-hash)
                       if (and (not (and (equal frame (selected-frame))
                                         (equal (persp-name persp) (persp-name (frame-parameter frame 'persp-curr)))))
                               (memq buffer (persp-buffers persp)))
                       do (cl-return-from persp-buffer-in-other-p
                            (cons frame (persp-name persp)))))
  nil)

(defun persp-switch-to-buffer (buffer-or-name)
  "Like `switch-to-buffer', but switches to another perspective if necessary."
  (interactive
   (list
    (let ((read-buffer-function nil))
      (read-buffer-to-switch "Switch to buffer: "))))
  (let ((buffer (window-normalize-buffer-to-switch-to buffer-or-name)))
    (if (memq buffer (persp-buffers (frame-parameter nil 'persp-curr)))
        (switch-to-buffer buffer)
      (let ((other-persp (persp-buffer-in-other-p buffer)))
        (when (eq (car-safe other-persp) (selected-frame))
          (persp-switch (cdr other-persp)))
        (switch-to-buffer buffer)))))

(defun persp-remove-buffer (buffer)
  "Disassociate BUFFER with the current perspective.

See also `persp-switch' and `persp-add-buffer'."
  (interactive "bRemove buffer from perspective: \n")
  (setq buffer (get-buffer buffer))
  (cond ((not (buffer-live-p buffer)))
        ;; Only kill the buffer if no other perspectives are using it
        ((not (persp-buffer-in-other-p buffer))
         (kill-buffer buffer))
        ;; Make the buffer go away if we can see it.
        ;; TODO: Is it possible to tell if it's visible at all,
        ;;       rather than just the current buffer?
        ((eq buffer (current-buffer)) (bury-buffer))
        (t (bury-buffer buffer)))
  (setf (persp-buffers (frame-parameter nil 'persp-curr)) (remq buffer (persp-buffers (frame-parameter nil 'persp-curr)))))

(defun persp-kill (name)
  "Kill the perspective given by NAME.

Killing a perspective means that all buffers associated with that
perspective and no others are killed."
  (interactive "i")
  (if (null name) (setq name (persp-prompt (persp-name (frame-parameter nil 'persp-curr)) t)))
  (with-perspective name
    (run-hooks 'persp-killed-hook)
    (mapc 'persp-remove-buffer (persp-buffers (frame-parameter nil 'persp-curr)))
    (setf (persp-killed (frame-parameter nil 'persp-curr)) t))
  (remhash name (frame-parameter nil 'perspectives-hash))
  (persp-update-modestring)
  (when (equal name (persp-name (frame-parameter nil 'persp-last)))
    (set-frame-parameter nil 'persp-last nil))
  (when (equal name (persp-name (frame-parameter nil 'persp-curr)))
    (persp-switch (persp-find-some))
    ;; Don't let persp-last get set to the deleted persp.
    (set-frame-parameter nil 'persp-last (frame-parameter nil 'nil))))

(defun persp-rename (name)
  "Rename the current perspective to NAME."
  (interactive "sNew name: ")
  (if (gethash name (frame-parameter nil 'perspectives-hash))
      (persp-error "Perspective `%s' already exists" name)
    (remhash (persp-name (frame-parameter nil 'persp-curr)) (frame-parameter nil 'perspectives-hash))
    (puthash name (frame-parameter nil 'persp-curr) (frame-parameter nil 'perspectives-hash))
    (setf (persp-name (frame-parameter nil 'persp-curr)) name)
    (persp-update-modestring)))

(cl-defun persp-all-get (name not-frame)
  "Returns the list of buffers for a perspective named NAME from any
frame other than NOT-FRAME.

This doesn't return the window configuration because those can't be
copied across frames."
  (dolist (frame (frame-list))
    (unless (equal frame not-frame)
      (with-selected-frame frame
        (let ((persp (gethash name (frame-parameter nil 'perspectives-hash))))
          (if persp (cl-return-from persp-all-get (persp-buffers persp))))))))

(defun persp-read-buffer (prompt &optional def require-match)
  "A replacement for the built-in `read-buffer'.
Meant to be used with `read-buffer-function'. Return the name of
the buffer selected, only selecting from buffers within the
current perspective.

With a prefix arg, uses the old `read-buffer' instead."
  (persp-protect
    (let ((read-buffer-function nil))
      (if current-prefix-arg
          (read-buffer prompt def require-match)
        ;; Most of this is taken from `minibuffer-with-setup-hook',
        ;; slightly modified because it's not a macro.
        ;; The only functional difference is that the append argument
        ;; to add-hook is t, so that it'll be run after the hook added
        ;; by `read-buffer-to-switch'.
        (let ((rb-completion-table (persp-complete-buffer))
              (persp-read-buffer-hook))
          (setq persp-read-buffer-hook
                (lambda ()
                  (remove-hook 'minibuffer-setup-hook persp-read-buffer-hook)
                  (setq minibuffer-completion-table rb-completion-table)))
          (unwind-protect
              (progn
                (add-hook 'minibuffer-setup-hook persp-read-buffer-hook t)
                (read-buffer prompt def require-match))
            (remove-hook 'minibuffer-setup-hook persp-read-buffer-hook)))))))

(defun persp-complete-buffer ()
  "Perform completion on all buffers within the current perspective."
  (lexical-let ((persp-names (mapcar 'buffer-name (persp-buffers (frame-parameter nil 'persp-curr)))))
    (apply-partially 'completion-table-with-predicate
                     (or minibuffer-completion-table 'internal-complete-buffer)
                     (lambda (name)
                       (member (if (consp name) (car name) name) persp-names))
                     nil)))

(cl-defun persp-import (name &optional dont-switch)
  "Import a perspective named NAME from another frame.  If DONT-SWITCH
is non-nil or with prefix arg, don't switch to the new perspective."
  ;; TODO: Have some way of selecting which frame the perspective is imported from.
  (interactive "i\nP")
  (unless name
    (setq name (funcall persp-interactive-completion-function
                        "Import perspective: " (persp-all-names (selected-frame)) nil t)))
  (if (and (gethash name (frame-parameter nil 'perspectives-hash))
           (not (yes-or-no-p (concat "Perspective `" name "' already exits. Continue? "))))
      (cl-return-from persp-import))
  (let ((buffers (persp-all-get name (selected-frame)))
        persp)
    (if (null buffers)
        (persp-error "Perspective `%s' doesn't exist in another frame" name))
    (setq persp (make-persp :name name :buffers buffers
                            (switch-to-buffer (cl-loop for buffer in buffers
                                                       if (buffer-live-p buffer)
                                                       return buffer))
                            (delete-other-windows)))
    (if dont-switch
        (persp-update-modestring)
      (persp-activate persp))))

(defadvice switch-to-buffer (after persp-add-buffer-adv)
  "Add BUFFER to the current perspective.

See also `persp-add-buffer'."
  (persp-protect
    (let ((buf (ad-get-arg 0)))
      (when buf
        (persp-add-buffer buf)))))

(defadvice display-buffer (after persp-add-buffer-adv)
  "Add BUFFER to the perspective for the frame on which it's displayed.

See also `persp-add-buffer'."
  (persp-protect
    (when ad-return-value
      (let ((buf (ad-get-arg 0))
            (frame (window-frame ad-return-value)))
        (when (and buf frame)
          (with-selected-frame frame
            (persp-add-buffer buf)))))))

(defadvice set-window-buffer (after persp-add-buffer-adv)
  "Add BUFFER to the perspective for window's frame.

See also `persp-add-buffer'."
  (persp-protect
    (let ((buf (ad-get-arg 1))
          (frame (window-frame (ad-get-arg 0))))
      (when (and buf frame)
        (with-selected-frame frame
          (persp-add-buffer buf))))))

(defadvice switch-to-prev-buffer (around persp-ensure-buffer-in-persp)
  "Ensure that the selected buffer is in WINDOW's perspective."
  (let* ((window (window-normalize-window window t))
         (frame (window-frame window))
         (old-buffer (window-buffer window)))
    ad-do-it

    (let ((buffer (window-buffer window)))
      (with-selected-frame frame
        (unless (memq buffer (persp-buffers (frame-parameter nil 'persp-curr)))
          ;; If a buffer from outside this perspective was selected, it's because
          ;; this perspective is out of buffers. For lack of any better option, we
          ;; recreate the scratch buffer.
          ;;
          ;; If we were just in a scratch buffer, change the name slightly.
          ;; Otherwise our new buffer will get deleted too.
          (let ((name (concat "*scratch* (" (persp-name (frame-parameter nil 'persp-curr)) ")")))
            (when (and bury-or-kill (equal name (buffer-name old-buffer)))
              (setq name (concat "*scratch*  (" (persp-name (frame-parameter nil 'persp-curr)) ")")))
            (with-selected-window window
              (switch-to-buffer name)
              (funcall initial-major-mode))))))))

(defadvice recursive-edit (around persp-preserve-for-recursive-edit)
  "Preserve the current perspective when entering a recursive edit."
  (persp-protect
    (persp-save)
    (set-frame-parameter nil 'persp-recursive (frame-parameter nil 'persp-curr))
    (let ((old-hash (copy-hash-table (frame-parameter nil 'perspectives-hash))))
      ad-do-it
      ;; We want the buffer lists that were created in the recursive edit,
      ;; but not the window configurations
      (maphash (lambda (key new-persp)
                 (let ((persp (gethash key old-hash)))
                   (when persp
                     (setf (persp-buffers persp) (persp-buffers new-persp)))))
               (frame-parameter nil 'perspectives-hash))
      (set-frame-parameter nil 'perspectives-hash old-hash))))

(defadvice exit-recursive-edit (before persp-restore-after-recursive-edit)
  "Restore the old perspective when exiting a recursive edit."
  (persp-protect
    (if (frame-parameter nil 'persp-recursive) (persp-switch (persp-name (frame-parameter nil 'persp-recursive))))))

;;;###autoload
(define-minor-mode persp-mode
  "Toggle perspective mode.
When active, keeps track of multiple 'perspectives',
named collections of buffers and window configurations."
  :global t
  :keymap persp-mode-map
  (if persp-mode
      (persp-protect
        (ad-activate 'switch-to-buffer)
        (ad-activate 'display-buffer)
        (ad-activate 'set-window-buffer)
        (ad-activate 'switch-to-prev-buffer)
        (ad-activate 'recursive-edit)
        (ad-activate 'exit-recursive-edit)
        (add-hook 'after-make-frame-functions 'persp-init-frame)
        (add-hook 'ido-make-buffer-list-hook 'persp-set-ido-buffers)
        (setq read-buffer-function 'persp-read-buffer)
        (mapc 'persp-init-frame (frame-list))
        (setf (persp-buffers (frame-parameter nil 'persp-curr)) (buffer-list))

        (run-hooks 'persp-mode-hook))
    (ad-deactivate-regexp "^persp-.*")
    (remove-hook 'after-make-frame-functions 'persp-init-frame)
    (remove-hook 'ido-make-buffer-list-hook 'persp-set-ido-buffers)
    (setq read-buffer-function nil)
    (set-frame-parameter nil 'perspectives-hash nil)
    (setq global-mode-string (delete '(:eval (persp-mode-line)) global-mode-string))
    (set-default 'header-line-format (delete '(:eval (persp-mode-line)) header-line-format))
    (unless (delete "" header-line-format)
      (set-default 'header-line-format nil))))

(defun persp-init-frame (frame)
  "Initialize the perspectives system in FRAME.
By default, this uses the current frame."
  (with-selected-frame frame
    (modify-frame-parameters
     frame
     '((perspectives-hash) (persp-curr) (persp-last) (persp-recursive) (persp-modestring)))

    ;; Don't set these variables in modify-frame-parameters
    ;; because that won't do anything if they've already been accessed
    (set-frame-parameter frame 'perspectives-hash (make-hash-table :test 'equal :size 10))

    (when persp-show-modestring
      (if (eq persp-show-modestring 'header)
          (let ((val (or (default-value 'header-line-format) '(""))))
            (unless (member '(:eval (persp-mode-line)) val)
              (set-default 'header-line-format (append val '((:eval (persp-mode-line)))))))
        (setq global-mode-string (or global-mode-string '("")))
        (unless (member '(:eval (persp-mode-line)) global-mode-string)
          (setq global-mode-string (append global-mode-string '((:eval (persp-mode-line)))))))
      (persp-update-modestring))

    (persp-activate
     (make-persp :name persp-initial-frame-name :buffers (list (current-buffer))
       :window-configuration (current-window-configuration)
       :point-marker (point-marker)))))

(defun persp-make-variable-persp-local (variable)
  "Make VARIABLE become perspective-local.
This means that whenever a new perspective is switched into, the
variable will take on its local value for that perspective.  When
a new perspective is created, the variable will inherit its value
from the current perspective at time of creation."
  (unless (assq variable (persp-local-variables (frame-parameter nil 'persp-curr)))
    (let ((entry (list variable (symbol-value variable))))
      (dolist (frame (frame-list))
        (cl-loop for persp being the hash-values of (frame-parameter frame 'perspectives-hash)
                 do (push entry (persp-local-variables persp)))))))

(defmacro persp-setup-for (name &rest body)
  "Add code that should be run to set up the perspective named NAME.
Whenever a new perspective named NAME is created, runs BODY in
it. In addition, if one exists already, runs BODY in it immediately."
  (declare (indent 1))
  `(progn
     (add-hook 'persp-created-hook
               (lambda ()
                 (when (string= (persp-name (frame-parameter nil 'persp-curr)) ,name)
                   ,@body))
               'append)
     (when (gethash ,name (frame-parameter nil 'perspectives-hash))
       (with-perspective ,name ,@body))))

(defun persp-set-ido-buffers ()
  "Restrict the ido buffer to the current perspective."
  (let ((persp-names
         (remq nil (mapcar 'buffer-name (persp-buffers (frame-parameter nil 'persp-curr)))))
        (indices (make-hash-table :test 'equal)))
    (cl-loop for elt in ido-temp-list
             for i upfrom 0
             do (puthash elt i indices))
    (setq ido-temp-list
          (sort (intersection persp-names ido-temp-list)
                (lambda (a b)
                  (< (gethash a indices)
                     (gethash b indices)))))))

(defun quick-perspective-keys ()
  "Bind quick key commands to switch to perspectives.
All C-S-letter key combinations are bound to switch to the first
perspective beginning with the given letter."
  (cl-loop for c from ?a to ?z
           do (define-key persp-mode-map
                (read-kbd-macro (concat "C-S-" (string c)))
                `(lambda ()
                   (interactive)
                   (persp-switch-quick ,c)))))

(defun persp-turn-off-modestring ()
  "Deactivate the perspective modestring."
  (interactive)
  (set-frame-parameter nil 'persp-modestring nil)
  (setq persp-show-modestring nil))

(defun persp-turn-on-modestring ()
  "Activate the perspective modestring."
  (interactive)
  (setq persp-show-modestring t)
  (persp-update-modestring))

(provide 'perspective)

;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; perspective.el ends here
