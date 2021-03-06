;;;; tutorial-part07.lisp
;;;; "The GUI"
;;;; February 2017
;;;;
;;;; Commentary to be posted on 9bladed.com
;;;;
;;;; Original python+libtcod tutorial, part 7:
;;;; http://www.roguebasin.com/index.php?title=Complete_Roguelike_Tutorial,_using_python%2Blibtcod,_part_7

(ql:quickload :tcod)
(ql:quickload :cl-utilities)

(defparameter *screen-width* 80)
(defparameter *screen-height* 50)
(defparameter *limit-fps* 20)

;; sizes and coordinates relevant for the GUI
(defparameter *bar-width* 20)
(defparameter *panel-height* 7)
(defparameter *panel-y* (- *screen-height* *panel-height*))

;; create the list of game messages and their colors, starts empty
(defparameter *game-msgs* (list (cons "" :white)))
(defparameter *msg-x* (+ *bar-width* 2))
(defparameter *msg-width* (- *screen-width* *bar-width* 2))
(defparameter *msg-height* (- *panel-height* 1))

(defparameter *mouse-event* nil)

(defvar *map*)
(defparameter *map-width* 80)
(defparameter *map-height* 43)

(defparameter *room-max-size* 10)
(defparameter *room-min-size* 6)
(defparameter *max-rooms* 30)
(defparameter *max-room-monsters* 3)

(defvar *fov-map* (tcod:map-new *map-width* *map-height*))
(defparameter *fov-recompute* t)
(defparameter *fov-algo* :FOV-BASIC)
(defparameter *fov-light-walls* t)
(defparameter *torch-radius* 10)

(tcod:make-color :dark-wall 0 0 100)
(tcod:make-color :light-wall 130 110 50)
(tcod:make-color :dark-ground 50 50 150)
(tcod:make-color :light-ground 200 180 50)

(tcod:console-set-custom-font "terminal16x16_gs_ro.png" '(:FONT-TYPE-GREYSCALE :FONT-LAYOUT-ASCII-IN-ROW))

(tcod:console-init-root *screen-width* *screen-height*
                        :title "lisp/libtcod tutorial" :fullscreen? nil :renderer :renderer-sdl)
(defparameter *con* (tcod:console-new *map-width* *map-height*))
(defparameter *panel* (tcod:console-new *screen-width* *panel-height*))

(tcod:sys-set-fps *limit-fps*)

(defun render-bar (x y total-width name value maximum bar-color back-color)
  ;; render a bar (HP, experience, etc.). first calculate the width of the bar
  (let ((bar-width (round (* (/ value maximum) total-width))))
    ;; render the background first
    (tcod:console-set-default-background *panel* (tcod:color back-color))
    (tcod:console-rect *panel* x y total-width 1 nil :screen)

    ;;now render the bar on top
    (tcod:console-set-default-background *panel* (tcod:color bar-color))
    (if (> bar-width 0)
        (tcod:console-rect *panel* x y bar-width 1 nil :screen))

    ;; finally, some centered text with the values
    (tcod:console-set-default-foreground *panel* (tcod:color :white))
    (tcod:console-print-ex *panel* (+ x (/ total-width 2)) y :none :center "~a: ~a/~a" name value maximum)))

(defun message (new-message &optional (color :white))
  ;; split the message if necessary, among multiple lines
  (let* ((words (cl-utilities:split-sequence #\space new-message))
        (format-string (format nil "~a~a~a" "~{~<~%~1," *msg-width* ":;~A~> ~}"))
        (new-lines (format nil "~@?" format-string words))
        (new-msg-lines (cl-utilities:split-sequence #\newline new-lines)))
    (dolist (line new-msg-lines)
      ;; if the buffer is full, remove the first line to make room for the new one
      ;; add the new line as a tuple, with the text and the color
      (if (eql (length *game-msgs*) *msg-height*)
          (setf *game-msgs* (append (cdr *game-msgs*) (list (cons line color))))
          (setf *game-msgs* (append  *game-msgs* (list (cons line color))))))))

(defgeneric move (obj dx dy)
  (:documentation "move by the given amount"))

(defgeneric move-towards (obj target-x target-y)
  (:documentation "move towards target"))

(defgeneric distance-to (obj other)
  (:documentation "return the distance to another object"))

(defgeneric draw (obj)
  (:documentation "set the color and then draw the character that represents this object at its position"))

(defgeneric clear (obj)
  (:documentation "erase the character that represents this object"))

(defgeneric send-to-back (obj)
  (:documentation "send object to beginning of list, to be drawn first and overwritten"))

(defclass tile ()
  ((blocked
    :initarg :blocked
    :initform (error "Must specify blocked")
    :accessor blocked)
   (block-sight
    :initarg :block-sight
    :initform nil
    :accessor block-sight)
   (explored
    :initform nil
    :accessor explored))
  (:documentation "a tile of the map and its properties"))

(defmethod initialize-instance :after ((tt tile) &key)
  "by default, if a tile is blocked, it also blocks sight"
  (if (not (block-sight tt))
      (setf (block-sight tt) (blocked tt))))

(defgeneric intersect (this other)
  (:documentation "returns true if this rectangle intersects with another one"))

(defclass rect ()
  ((x1
    :initarg :x1
    :initform (error "Must have an x value")
    :accessor x1)
   (y1
    :initarg :y1
    :initform (error "Must have a y value")
    :accessor y1)
   (x2
    :accessor x2)
   (y2
    :accessor y2)
   (center
    :accessor center))
  (:documentation "a rectangle on the map. used to characterize a room."))

(defmethod initialize-instance :after ((r rect) &key width height)
  (setf (x2 r) (+ (x1 r) width))
  (setf (y2 r) (+ (y1 r) height))
  (setf (center r) (cons (floor (/ (+ (x1 r) (x2 r)) 2)) (floor (/ (+ (y1 r) (y2 r)) 2)))))

(defmethod intersect ((this rect) (other rect))
           (and (<= (x1 this) (x2 other)) (>= (x2 this) (x1 other))
                (<= (y1 this) (y2 other)) (>= (y2 this) (y1 other))))

(defun create-room (room)
  ;; go through the tiles in the rectangle and make them passable
  (loop for x from (1+ (x1 room)) below (x2 room)
     do (loop for y from (1+ (y1 room)) below (y2 room)
           do (setf (blocked (aref *map* y x)) nil)
           do (setf (block-sight (aref *map* y x)) nil))))

(defun create-h-tunnel (x1 x2 y)
  (loop for x from (min x1 x2) upto (max x1 x2)
     do (setf (blocked (aref *map* y x)) nil)
     do (setf (block-sight (aref *map* y x)) nil)))

(defun create-v-tunnel (y1 y2 x)
  ;; vertical tunnel
  (loop for y from (min y1 y2) upto (max y1 y2)
     do (setf (blocked (aref *map* y x)) nil)
       (setf (block-sight (aref *map* y x)) nil)))

(defun is-blocked (x y)
  ;; first test the map tile
  (if (blocked (aref *map* y x))
      t
      ;; now check for any blocking objects
      (dolist (obj *objects*)
        (if (and (blocks obj) (eql (x obj) x) (eql (y obj) y))
            (return t)))))

(defclass object ()
  ((x
    :initarg :x
    :initform (error "Must have an x value")
    :accessor x)
   (y
    :initarg :y
    :initform (error "Must have a y value")
    :accessor y)
   (cha
    :initarg :cha
    :initform (error "Must have a character")
    :accessor cha)
   (color
    :initarg :color
    :initform (error "Must have a color")
    :accessor color)
   (name
    :initarg :name
    :initform (error "Must have a name")
    :accessor name)
   (blocks
    :initarg :blocks
    :initform nil
    :accessor blocks)
   (ai
    :initarg :ai
    :initform nil
    :accessor ai))
  (:documentation "this is a generic object: the player, a monster, an item, the stairs...
                   it's always represented by a character on the screen."))

(defmethod move ((obj object) dx dy)
  (if (not (is-blocked (+ (x obj) dx) (+ (y obj) dy)))
      (progn
        (incf (x obj) dx)
        (incf (y obj) dy))))

(defmethod move-towards ((obj object) target-x target-y)
  ;; vector from this object to the target, and distance
  (let* ((dx (- target-x (x obj))) (dy (- target-y (y obj)))
         (distance (sqrt (+ (expt dx 2) (expt dy 2)))))
    ;; normalize it to length 1 (preserving direction), then round it and
    ;; convert to integer so the movement is restricted to the map grid
    (setf dx (round (/ dx distance))
          dy (round (/ dy distance)))
    (move obj dx dy)))

(defmethod distance-to ((obj object) (other object))
  (let ((dx (- (x other) (x obj))) (dy (- (y other) (y obj))))
    (sqrt (+ (expt dx 2) (expt dy 2)))))

(defmethod move-or-attack ((obj object) dx dy)
  ;;the coordinates the player is moving to/attacking
  (let ((x (+ (x obj) dx)) (y (+ (y obj) dy)) (target nil))
    ;;try to find an attackable object there
    (dolist (object *objects*)
      (when (and (ai object) (eql (x object) x) (eql (y object) y))
          (setf target object)
          (return)))

    ;; attack if target found, move otherwise
    (if target
        (attack *player* target)
        (progn (move obj dx dy)
               (setf *fov-recompute* t)))))

(defmethod draw ((obj object))
  (when (tcod:map-is-in-fov? *fov-map* (x obj) (y obj))
    (tcod:console-set-default-foreground *con* (tcod:color (color obj)))
    (tcod:console-put-char *con* (x obj) (y obj) (char-code (cha obj)) :NONE)))

(defmethod clear ((obj object))
  (tcod:console-put-char *con* (x obj) (y obj) (char-code #\SPACE) :NONE))

(defmethod send-to-back ((obj object))
  ;; make this object be drawn first, so all others appear above it if they're in the same tile
  (setf *objects* (remove obj *objects*))
  (push obj *objects*))

(defclass fighter (object)
  ((max-hp
    :initarg :max-hp
    :initform (error "Must provide max-hp")
    :accessor max-hp)
   (hp
    :accessor hp)
   (defense
     :initarg :defense
     :initform (error "Must provide defense")
     :accessor defense)
   (power
    :initarg :power
    :initform (error "Must provide power")
    :accessor power)
   (death-fun
    :initarg :death-fun
    :initform nil
    :accessor death-fun))
  (:documentation "fighter class for players, npcs, monsters"))

(defmethod initialize-instance :after ((f fighter) &key)
  (setf (hp f) (max-hp f)))

(defgeneric take-damage (self damage)
  (:documentation "take damage"))

(defgeneric attack (self target)
  (:documentation "attack target"))

(defmethod attack ((self fighter) target)
  ;; a simple formula for attack damage
  (let ((damage (- (power self) (defense target))))
    (if (> damage 0)
        ;; make the target take some damage
        (progn (message (format nil "~&~@(~a~) attacks ~a for ~a hit points."
                                (name self) (name target) damage))
               (take-damage target damage))
        (message (format nil "~&~@(~a~) attacks ~a but it has no effect!"
                         (name self) (name target))))))

(defmethod take-damage ((self fighter) damage)
  ;; apply damage if possible
  (if (> damage 0)
      (decf (hp self) damage))
  ;; check for death. if there's a death function, call it
  (if (<= (hp self) 0)
      (if (death-fun self)
          (funcall (death-fun self) self))))

(defgeneric take-turn (self)
  (:documentation "take turn"))

(defclass basic-monster (object)
  ((ai
    :initform #'take-turn))
  (:documentation "AI for a basic monster"))

(defmethod take-turn ((monster basic-monster))
  "a basic monster takes its turn. If you can see it, it can see you"
  (if (tcod:map-is-in-fov? *fov-map* (x monster) (y monster))
      (cond
        ;; move towards player if far away
        ((>= (distance-to monster *player*) 2)
         (move-towards monster (x *player*) (y *player*)))
        ;; close enough, attack! (if the player s still alive.)
        ((> (hp *player*) 0)
         (attack monster *player*)))))

(defclass basic-fighter-monster (fighter basic-monster)
  ())

(defun player-death (player)
  ;; the game ended!
  (message "You died!" :red)
  (setf *game-state* :dead)

  ;; for added effect, transform the player into a corpse!
  (setf (cha player) #\%
        (color player) :dark-red))

(defun monster-death (monster)
  ;; transform it into a nasty corpse! it doesn't block, can't be
  ;; attacked and doesn't move
  (message (format nil "~&~@(~a~) is dead!" (name monster)) :orange)
  (setf (cha monster) #\%
        (color monster) :dark-red
        (blocks monster) nil
        (ai monster) nil
        (name monster) (format nil "remains of ~a" (name monster)))
  (send-to-back monster))

(defun place-objects (room)
  ;; choose random number of monsters
  (let ((num-monsters (tcod:random-get-int tcod:+null+ 0 *max-room-monsters*))
        monster x y)
    (dotimes (i num-monsters)
      ;; choose random spot for this monster
      (setf x (tcod:random-get-int tcod:+null+ (x1 room) (x2 room))
            y (tcod:random-get-int tcod:+null+ (y1 room) (y2 room)))

      (unless (is-blocked x y)
        (if (< (tcod:random-get-int tcod:+null+ 0 100) 80) ; 80% chance of getting an orc
            ;; create an orc
            (setf monster (make-instance 'basic-fighter-monster
                                         :x x :y y :cha #\o :name "orc" :color :pale-green
                                         :blocks t :max-hp 10 :defense 0 :power 3
                                         :death-fun #'monster-death))
            ;; create a troll
            (setf monster (make-instance 'basic-fighter-monster
                                         :x x :y y :cha #\T :name "troll" :color :dark-sea-green
                                         :blocks t :max-hp 10 :defense 1 :power 4
                                         :death-fun #'monster-death)))

        (setf *objects* (append *objects* (list monster)))))))

(defun handle-keys (event)
  (cond ((and (eql (tcod:key-vk event) :ENTER) (tcod:key-lalt event))
         (tcod:console-set-fullscreen (not (tcod:console-is-fullscreen?))))
        ((eql (tcod:key-vk event) :ESCAPE) (return-from handle-keys :exit)))
  (if (eql *game-state* :playing)
      (cond
        ;; movement keys
        ((eql (tcod:key-vk event) :UP)
         (move-or-attack *player* 0 -1))
        ((eql (tcod:key-vk event) :DOWN)
         (move-or-attack *player* 0 1))
        ((eql (tcod:key-vk event) :LEFT)
         (move-or-attack *player* -1 0))
        ((eql (tcod:key-vk event) :RIGHT)
         (move-or-attack *player* 1 0))
        (t (return-from handle-keys :didnt-take-turn)))))

(defun get-mouse-events ()
  (let ((events (tcod:sys-wait-events :event-mouse t)))
    (loop for ev in events
       when (eql (car ev) :event-mouse-move)
       collect (cdr ev) into mouse-events
         finally (return mouse-events))))

(defun get-names-under-mouse (event)
  ;;returns a string with the names of all objects under the mouse
  (if (not event)
      (return-from get-names-under-mouse ""))
  (let* ((x (tcod:mouse-cx event)) (y (tcod:mouse-cy event))
         (fov (tcod:map-is-in-fov? *fov-map* x y)))
    (loop for obj in *objects*
       when (and (eql (x obj) x) (eql (y obj) y) fov)
       collect (name obj) into obj-names
       finally (return (format nil "~{~@(~a~^, ~)~}" obj-names)))))

(defparameter *player* (make-instance 'fighter
                                      :x 0 :y 0 :cha #\@ :name "player" :color :white :blocks t
                                      :max-hp 30 :defense 2 :power 5 :death-fun #'player-death))
(defparameter *objects* (list *player*))

(defun make-map ()
  (setf *map* (make-array (list *map-height* *map-width*)))
  (dotimes (i *map-height*)
    (dotimes (j *map-width*)
      (setf (aref *map* i j) (make-instance 'tile :blocked t))))

  (loop with num-rooms = 0
     with rooms
     with w
     with h
     with x
     with y
     with new-room
     with failed
     for r from 0 below *max-rooms* do
       ;; random width and height
       (setf w (tcod:random-get-int tcod:+null+ *room-min-size* *room-max-size*))
       (setf h (tcod:random-get-int tcod:+null+ *room-min-size* *room-max-size*))

       ;; random position without going out of the boundaries of the map
       (setf x (tcod:random-get-int tcod:+null+ 0 (- *map-width* w 1)))
       (setf y (tcod:random-get-int tcod:+null+ 0 (- *map-height* h 1)))

       ;; "rect" class makes rectangles easier to work with
       (setf new-room (make-instance 'rect :x1 x :y1 y :width w :height h))

       ;; run through the other rooms and see if they intersect with this one
       (setf failed nil)
       (loop for other-room in rooms do
            (when (intersect new-room other-room)
              (setf failed t)
              (return)))
       (unless failed
         ;; this means there are no intersections, so this room is valid

         (create-room new-room) ; "paint" it to the map's tiles

         ;; center coordinates of new room, will be useful later
         (let ((new-x (car (center new-room)))
               (new-y (cdr (center new-room))))
           (cond ((eql num-rooms 0)
                  ;; this is the first room, where the player starts at
                  (setf (x *player*) new-x
                        (y *player*) new-y))
                 ;; all rooms after the first:
                 ;; connect it to the previous room with a tunnel
                 (t (let ((prev-x (car (center (car (last rooms))))) ; center coordinates
                          (prev-y (cdr (center (car (last rooms)))))) ; of previous room
                      ;; draw a coin (random number that is either 0 or 1)
                      (cond ((eql (tcod:random-get-int tcod:+null+ 0 1) 1)
                             ;; first move horizontally, then vertically
                             (create-h-tunnel prev-x new-x prev-y)
                             (create-v-tunnel prev-y new-y new-x))
                            (t ; first move vertically, then horizontally
                             (create-v-tunnel prev-y new-y prev-x)
                             (create-h-tunnel prev-x new-x new-y)))))))

         ;; add some contents to this room, such as monsters
         (place-objects new-room)
         
         ;; finally, append the new room to the list
         (if (eql num-rooms 0)
             (setf rooms (list new-room))
             (setf rooms (append rooms (list new-room))))
         (incf num-rooms))))

;; generate map (at this point it's not drawn to the screen)
(make-map)

(dotimes (y *map-height*)
  (dotimes (x *map-width*)
    (tcod:map-set-properties *fov-map* x y (not (block-sight (aref *map* y x)))
                             (not (blocked (aref *map* y x))))))

(defun render-all ()
  (when *fov-recompute*
    ;; recompute FOV if needed (the player moved or something)
    (setf *fov-recompute* nil)
    (tcod:map-compute-fov *fov-map* (x *player*) (y *player*) *torch-radius*
                          *fov-light-walls* *fov-algo*))
  
  ;; go through all the tiles, and set their background color
  (dotimes (i *map-height*)
    (dotimes (j *map-width*)
      (let ((visible (tcod:map-is-in-fov? *fov-map* j i))
            (wall (block-sight (aref *map* i j))))
        (if (not visible)
            ;; if it's not visible right now, the player can only see it if it's explored
            (if (explored (aref *map* i j))
                ;; it's out of the player's FOV
                (if wall
                    (tcod:console-set-char-background *con* j i (tcod:color :dark-wall) :set)
                    (tcod:console-set-char-background *con* j i (tcod:color :dark-ground) :set)))
          ;; it's visible
            (progn (if wall
                       (tcod:console-set-char-background *con* j i (tcod:color :light-wall) :set)
                       (tcod:console-set-char-background *con* j i (tcod:color :light-ground) :set))
                   ;; since it's visible, explore it
                   (setf (explored (aref *map* i j)) t))))))

  ;; draw all objects in the list, except the player. we want it to
  ;; always appear over all other objects! so it's drawn later.
  (dolist (obj *objects*)
    (if (not (eql obj *player*))
        (draw obj)))
  (draw *player*)

  ;; blit the contents of con to the root console
  (tcod:console-blit *con* 0 0 *map-width* *map-height* tcod:*root* 0 0 1.0 1.0)
  
  ;; prepare to render the GUI panel
  (tcod:console-set-default-background *panel* (tcod:color :black))
  (tcod:console-clear *panel*)

  ;; print the game messages, one line at a time
  (loop for (line . color) in *game-msgs*
     and y from 1 do
       (tcod:console-set-default-foreground *panel* (tcod:color color))
       (tcod:console-print-ex *panel* *msg-x* y :none :left line))

  ;; show the player's stats
  (render-bar 1 1 *bar-width* "HP" (hp *player*) (max-hp *player*) :light-red :dark-red)

  ;; display names of objects under the mouse
  (tcod:console-set-default-background *panel* (tcod:color :slate-gray))
  (tcod:console-print-ex *panel* 1 0 :none :left (get-names-under-mouse *mouse-event*))

  ;; blit the contents of "panel" to the root console
  (tcod:console-blit *panel* 0 0 *screen-width* *panel-height* tcod:*root* 0 *panel-y* 1.0 1.0))

(defparameter *game-state* :playing)
(defparameter *player-action* nil)

(message "Welcome stranger! Prepare to perish in the Tombs of the Ancient Kings." :red)

(do ()
    ((tcod:console-is-window-closed?))
  (render-all)
  (tcod:console-flush)
  (mapcar #'clear *objects*)
  (setf *player-action* :didnt-take-turn)
  (dolist (event (tcod:sys-get-events))
    (if (eql (car event) :event-key-press)
        (setf *player-action* (handle-keys (cdr event)))
        (if (eql (car event) :event-mouse-move)
            (setf *mouse-event* (cdr event)))))
  ;; let monsters take their turn
  (if (and (eql *game-state* :playing) (not (eql *player-action* :didnt-take-turn)))
      (dolist (obj *objects*)
        (if (ai obj)
            (take-turn obj))))
  (if (eql *player-action* :exit)
      (return)))
