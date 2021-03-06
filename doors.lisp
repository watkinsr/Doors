;;;; Copyright (C) 2020  Andrea De Michele
;;;;
;;;; This library is free software; you can redistribute it and/or
;;;; modify it under the terms of the GNU Lesser General Public
;;;; License as published by the Free Software Fuondation; either
;;;; version 2.1 of the License, or (at your option) any later version.
;;;;
;;;; This library is distributed in the hope that it will be useful,
;;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;;; Lesser General Public License for more details.
;;;;
;;;; You should have received a copy of the GNU Lesser General Public
;;;; License along with this library; if not, write to the Free Software
;;;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301
;;;; USA

(in-package #:doors)


;; Xephyr -br -ac -noreset -screen 1920x1080 :1
;; (setf clim:*default-server-path* (list :doors :mirroring :single))
(setf clim:*default-server-path* (list :doors ))

(swank/backend:install-debugger-globally #'clim-debugger:debugger)

(defparameter *grabbed-keystrokes* nil)

(defparameter *config-file* (merge-pathnames "doors/config.lisp" (uiop:xdg-config-home)))

(define-application-frame doors ()
  ()
  (:panes
   (desktop (make-pane :bboard-pane :background +gray+))
   (info :application
         :incremental-redisplay t
         :display-function 'display-info :max-height 15 :scroll-bars nil)
   (interactor :interactor :height 24)
   (pointer-doc :pointer-documentation :scroll-bars nil)
   (tray (make-pane 'doors-systray:tray-pane :background +white+)))
  (:layouts (with-interactor (vertically (:width (graft-width (find-graft)) :height (graft-height (find-graft)))
                               (:fill desktop) (make-pane 'clime:box-adjuster-gadget)  interactor pointer-doc (horizontally () (:fill info) tray)))
            (without-interactor (vertically (:width (graft-width (find-graft)) :height (graft-height (find-graft)))
                                  (:fill desktop) (horizontally () (:fill info) tray)))))

(defmethod generate-panes :after (fm (frame doors))
  (clime:port-all-font-families (port fm)))

(defun managed-frames (&optional (wm *wm-application*))
  (clime:port-all-font-families (port wm))
  (loop for fm in (climi::frame-managers (port wm))
     unless (eql fm (frame-manager wm))
     appending (frame-manager-frames fm)))

(defmethod default-frame-top-level :around ((frame doors) &key &allow-other-keys)
  (with-frame-manager ((find-frame-manager :port (port frame) :fm-type :stack))
    (call-next-method)))


;; ;;; The parameter STATE is a bit mask represented as the logical OR
;; ;;; of individual bits.  Each bit corresponds to a modifier or a
;; ;;; pointer button that is active immediately before the key was
;; ;;; pressed or released.  The bits have the following meaning:
;; ;;;
;; ;;;   position  value    meaning
;; ;;;     0         1      shift
;; ;;;     1         2      lock
;; ;;;     2         4      control
;; ;;;     3         8      mod1
;; ;;;     4        16      mod2
;; ;;;     5        32      mod3
;; ;;;     6        64      mod4
;; ;;;     7       128      mod5
;; ;;;     8       256      button1
;; ;;;     9       512      button2
;; ;;;    10      1024      button3
;; ;;;    11      2048      button4
;; ;;;    12      4096      button5

(defun keystroke-to-keycode-and-state (keystroke port)
  "Return x11 keycode and state from a keystroke"
  (let* ((mod-values '((:shift . 1) (:control . 4) (:meta . 8) (:super . 64)))
         (display (clim-clx::clx-port-display port))
         (key (car keystroke))
         (modifiers (cdr keystroke))
         (keysym (if (characterp key)
                     (first (xlib:character->keysyms key display))
                     (clim-xcommon:keysym-name-to-keysym key)))
         (keycode (xlib:keysym->keycodes display keysym))
         (shift? (cond
                   ((= keysym (xlib:keycode->keysym display keycode 0))
                    nil)
                   ((= keysym (xlib:keycode->keysym display keycode 1))
                    t)
                   (t (error "Error in find the keycode of char ~S" char))))
         state)
    (when shift? (pushnew :shift modifiers))
    ;; maybe is better to use logior
    (setf state (loop for i in modifiers sum (alexandria:assoc-value mod-values i)))
    (values keycode state)))

(defun grab/ungrab-keystroke (keystroke &key (port (find-port)) (ungrab nil))
  (let* ((display (clim-clx::clx-port-display port))
         (root (clim-clx::clx-port-window port)))
    (multiple-value-bind (code state) (keystroke-to-keycode-and-state keystroke port)
      (if ungrab
          (xlib:ungrab-key root code :modifiers state)
          (xlib:grab-key root code :modifiers state)))
    (xlib:display-finish-output display)))

(defmethod run-frame-top-level :around ((frame doors)
                                        &key &allow-other-keys)
  (unwind-protect
       (progn
         (load *config-file*)
         (loop for key in *grabbed-keystrokes* do
              (grab/ungrab-keystroke key))
		     ;; (xlib:intern-atom  (clim-clx::clx-port-window (find-port)) :_MOTIF_WM_HINTS)

         (setf (xlib:window-event-mask (clim-clx::clx-port-window (find-port))) '(:substructure-notify :substructure-redirect))
         #+clx-ext-randr
         (xlib:rr-select-input (clim-clx::clx-port-window (find-port)) '(:screen-change-notify-mask :crtc-change-notify-mask))
         (call-next-method))
    (loop for key in *grabbed-keystrokes* do
         (grab/ungrab-keystroke key :ungrab t))))


(defmethod run-frame-top-level :before ((frame doors) &key &allow-other-keys)
  (queue-event (find-pane-named frame 'info) (make-instance 'info-line-event :sheet frame)))

(defclass info-line-event (window-manager-event) ())

(defmethod handle-event ((frame doors) (event info-line-event))
  (with-application-frame (frame)
    (redisplay-frame-pane frame 'info))
  (clime:schedule-event (find-pane-named frame 'info)
                  (make-instance 'info-line-event :sheet frame)
                  1))

(defmacro define-doors-command-with-grabbed-keystroke (name-and-options arguments &rest body)
  (let* ((name (if (listp name-and-options)
                   (first name-and-options)
                   name-and-options))
         (options (if (listp name-and-options)
                      (cdr name-and-options)
                      nil))
         (keystroke (getf options :keystroke)))
    `(progn
       (define-doors-command (,name ,@options)
       ,arguments ,@body)
       (when ',keystroke (pushnew ',keystroke *grabbed-keystrokes*))
       (when *wm-application* (grab/ungrab-keystroke ',keystroke)))))


(defun find-foreign-application (win-class)
  (let ((table (slot-value (port *wm-application*) 'clim-doors::foreign-mirror->sheet)))
    (loop for pane being the hash-value of table
        when (string= win-class (xlib:get-wm-class (clim-doors::foreign-xwindow pane)))
       collect (pane-frame pane))))

(defmacro define-run-or-raise (name sh-command win-class keystroke)
  `(define-doors-command-with-grabbed-keystroke (,name :name t :keystroke ,keystroke)
       ()
     (alexandria:if-let (frames (find-foreign-application ,win-class))
       (setf (active-frame (port *application-frame*)) (car frames))
       (uiop:launch-program ,sh-command))))

;; DEBUG wm-classes for all frames
;; (loop for pane being the hash-value of (slot-value (port *wm-application*) 'clim-doors::foreign-mirror->sheet)
;;            collect (xlib:get-wm-class (clim-doors::foreign-xwindow pane)))


;; Form a hashtable such that the key is the browser and the value is WM_CLASS

(setq browser-ht (make-hash-table :test 'equal))
(setf (gethash "vivaldi-stable" browser-ht) "vivaldi-stable")
(setf (gethash "chrome" browser-ht) "chromium-browser")
(setq browser (uiop:getenv "BROWSER"))
(setq browser-class (gethash browser browser-ht))

(define-run-or-raise com-file "st -c lf -n lf -e /home/ryan/go/bin/lf" "lf" (#\z :super))

(define-run-or-raise com-pdf "zathura" "org.pwmt.zathura" (#\B :super))

(define-run-or-raise com-emacs "emacs" "emacs" (#\E :super))

(define-run-or-raise com-browser browser browser-class (#\b :super))

(define-run-or-raise com-terminal "st" "st" (#\c :super))

(define-run-or-raise com-capture "/home/ryan/.emacs.d/bin/org-capture" "org-capture" (#\X :super))

(define-doors-command-with-grabbed-keystroke (com-listener :name t :keystroke (#\l :super))
    ()
  (let ((frame (car (member "Listener" (managed-frames) :key  #'frame-pretty-name  :test #'string=))))
    (if frame
        (setf (active-frame (port *application-frame*)) frame)
        (clim-listener:run-listener :width 1000 :height 600 :new-process t))))

(define-doors-command-with-grabbed-keystroke (com-new-listener :name t :keystroke (#\L :super))
    ()
  (clim-listener:run-listener :width 1000 :height 600 :new-process t))

(define-doors-command-with-grabbed-keystroke (com-editor :name t :keystroke (#\e :super))
    ()
  (find-application-frame 'climacs::climacs))

(define-doors-command-with-grabbed-keystroke (com-next-frame :name t :keystroke (#\n :super))
    ()
  (alexandria:when-let ((frames (managed-frames)))
    (let* ((old-active (active-frame (port *application-frame*)))
           (old-position (or (position old-active frames) 0))
           (new-active (nth (mod (1+ old-position) (length frames)) frames)))
      (setf (active-frame (port *application-frame*)) new-active))))

(define-doors-command-with-grabbed-keystroke (com-previous-frame :name t :keystroke (#\p :super))
    ()
  (alexandria:when-let ((frames (managed-frames)))
    (let* ((old-active (active-frame (port *application-frame*)))
           (old-position (or (position old-active frames) 0))
           (new-active (nth (mod (1- old-position) (length frames)) frames)))
      (setf (active-frame (port *application-frame*)) new-active))))

(define-doors-command-with-grabbed-keystroke (com-banish-pointer :name t :keystroke (#\. :super))
    ()
  (setf (pointer-position (port-pointer (port *application-frame*)))
        (values (graft-width (graft *application-frame*))
                (graft-height (graft *application-frame*)))))

(define-doors-command (com-frame-focus :name t)
    ((frame 'application-frame :gesture :select))
  (setf (active-frame (port *application-frame*)) frame))

(define-doors-command (com-frame-toggle-fullscreen :name t)
    ((frame 'application-frame :default (active-frame (port *application-frame*))))
  (if (typep (frame-manager frame) 'clim-doors::doors-fullscreen-frame-manager)
      (progn
        (setf (frame-manager frame) (find-frame-manager :port (port frame) :fm-type :stack)))
      (progn
        (save-frame-geometry frame)
        (setf (frame-manager frame) (find-frame-manager :port (port frame) :fm-type :fullscreen))))
  (setf (active-frame (port frame)) frame))

(define-doors-command-with-grabbed-keystroke (com-fullscreen :name t :keystroke (#\Space :super))
    ()
  (let ((frame  (active-frame (port *application-frame*))))
    (when (member frame (managed-frames))
      (com-frame-toggle-fullscreen frame))))

(define-doors-command (com-frame-toggle-tiled :name t)
    ((frame 'application-frame :default (active-frame (port *application-frame*))))
  (if (typep (frame-manager frame) 'clim-doors::doors-tile-frame-manager)
      (progn
        (setf (frame-manager frame) (find-frame-manager :port (port frame) :fm-type :stack)))
      (progn
        (save-frame-geometry frame)
        (setf (frame-manager frame) (find-frame-manager :port (port frame) :fm-type :tile))))
  (setf (active-frame (port frame)) frame))

(define-doors-command-with-grabbed-keystroke (com-tiled :name t :keystroke (#\q :super))
    ()
  (let ((frame  (active-frame (port *application-frame*))))
    (when (member frame (managed-frames))
      (com-frame-toggle-tiled frame))))

(define-doors-command-with-grabbed-keystroke (com-maximize :name t :keystroke (#\m :super))
    ()
  (let ((frame  (active-frame (port *application-frame*))))
    (when (and (member frame (managed-frames)) (eql (frame-manager frame) (find-frame-manager :port (port frame) :fm-type :stack)))
      (let* ((tls (frame-top-level-sheet frame))
             (desktop-region (sheet-region (find-pane-named *wm-application* 'desktop)))
             (w (bounding-rectangle-width desktop-region))
             (h (bounding-rectangle-height desktop-region)))
        (move-and-resize-sheet tls 0 0 w h)))))

(define-presentation-to-command-translator
    com-frame-toggle-fullscreen
    (application-frame com-frame-toggle-fullscreen doors
     :documentation "Toggle Fullscreen")
    (object)
    (list object))

(define-doors-command-with-grabbed-keystroke (com-dmenu :keystroke (#\Return :super))
    ()
  (uiop:run-program "dmenu_run -fn \"Fixedsys Excelsior\" -i -b -p \"run command:\""))


(define-doors-command (com-run :name t)
    ((command `(member-sequence
                ,(loop for dir  in (ppcre:split ":" (uiop:getenv "PATH"))
                    appending (map 'list #'pathname-name (uiop:directory-files (uiop:ensure-directory-pathname dir)))))
              :prompt "Command")
     (args '(or null (sequence string)) :prompt "Arguments" :default '()))
  (format (frame-query-io *application-frame*) "~s" (cons command args))
  (uiop:launch-program (cons command args)))

(define-doors-command-with-grabbed-keystroke (com-bury-all :name t :keystroke (#\_ :super))
    ()
  (let* ((frames (managed-frames)))
    (map nil #'bury-frame frames)))

(define-doors-command-with-grabbed-keystroke (com-goto-wm-interactor :keystroke (#\i :super))
    ()
  (setf (frame-current-layout *wm-application*) 'with-interactor)
  (stream-set-input-focus (frame-standard-input *wm-application*)))

(define-doors-command-with-grabbed-keystroke (com-toggle-interactor
                                             :keystroke     (#\I :super))
    ()
  (let ((frame *application-frame*))
    (setf (frame-current-layout frame)
          (case (frame-current-layout frame)
            (with-interactor    'without-interactor)
            (without-interactor 'with-interactor)))))

(define-doors-command-with-grabbed-keystroke (com-quit :name t :keystroke (#\Q :super))
    ()
  (setf *wm-application* nil)
  (frame-exit *application-frame*))

(define-doors-command (com-frame-kill :name t)
    ((frame 'application-frame :gesture :delete))
  (queue-event (frame-top-level-sheet frame)
               (make-instance 'window-manager-delete-event :sheet (frame-top-level-sheet frame))))

(define-doors-command-with-grabbed-keystroke (com-kill :keystroke (#\K :super))
    ()
  (let ((frame  (active-frame (port *application-frame*))))
    (when (member frame (managed-frames))
      (com-frame-kill frame))))

;;;; MULTIMEDIA

(define-doors-command-with-grabbed-keystroke (com-audio-mute :name t :keystroke (:xf86-audio-mute))
    ()
  (let* ((out (uiop:run-program "amixer -D default sset Master toggle" :output :string))
         (state (cl-ppcre:scan-to-strings "\\[(on|off)\\]" out)))
    (format (frame-query-io *application-frame*) "Audio: ~a" state)))

(define-doors-command-with-grabbed-keystroke (com-audio-increase-volume :name t :keystroke (:xf86-audio-raise-volume))
    ()
  (let* ((out (uiop:run-program "amixer -D default sset Master 1%+" :output :string))
         (state (cl-ppcre:scan-to-strings "\\[([0-9]*%)\\]" out)))
    (format (frame-query-io *application-frame*) "Audio Volume: ~a" state)))

(define-doors-command-with-grabbed-keystroke (com-audio-decrease-volume :name t :keystroke (:xf86-audio-lower-volume))
    ()
  (let* ((out (uiop:run-program "amixer -D default sset Master 1%-" :output :string))
         (state (cl-ppcre:scan-to-strings "\\[([0-9]*%)\\]" out)))
    (format (frame-query-io *application-frame*) "Audio Volume: ~a" state)))

(defun doors (&key new-process)
  ;; maybe is necessary to control if therreis another instance
  (let* ((port (find-port))
         (fm (find-frame-manager :port (find-port) :fm-type :onroot))
         (frame (make-application-frame 'doors
                                        :frame-manager fm
                                        :width (graft-width (find-graft))
                                        :height (graft-height (find-graft)))))
    (setf *wm-application* frame)
    (if new-process
        (clim-sys:make-process #'(lambda () (run-frame-top-level frame)) :name "Doors WM")
        (run-frame-top-level frame))))

(defun start-tray ()
  (doors-systray:start-tray (find-pane-named *wm-application* 'tray)))
