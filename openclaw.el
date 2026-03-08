;;; openclaw.el --- Emacs interface to OpenClaw -*- lexical-binding: t; coding: utf-8; -*-

;; Copyright (C) 2026 Kyvero Vexus Corporation

;; Author: Kyvero Vexus <contact@kyverovexus.org>
;; URL: https://github.com/Kyvero-Vexus/openclaw.el
;; Keywords: comm tools ai
;; Version: 0.2.0
;; Package-Requires: ((emacs "27.1") (websocket "1.15"))

;; This file is part of openclaw.el.

;; openclaw.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; openclaw.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public License
;; along with openclaw.el.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This package provides an Emacs interface to OpenClaw with TUI feature parity.
;;
;; Quick start:
;;   M-x openclaw-connect RET
;;   M-x openclaw-chat RET
;;
;; Keybindings (when in openclaw-chat-mode):
;;   C-c C-c   - Send message
;;   C-c C-l   - List sessions
;;   C-c C-s   - Switch session
;;   C-c C-n   - New chat
;;   C-c C-a   - Abort current run
;;   C-c C-m   - Model picker
;;   C-c C-p   - Session picker
;;   C-c C-h   - Show history
;;   C-c C-q   - Close connection

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'websocket)
(require 'button)


;;; Customization

(defgroup openclaw nil
  "Emacs interface to OpenClaw."
  :group 'comm
  :prefix "openclaw-")

(defcustom openclaw-gateway-url "ws://127.0.0.1:18789"
  "URL of the OpenClaw gateway."
  :type 'string
  :group 'openclaw)

(defcustom openclaw-gateway-token nil
  "Authentication token for the OpenClaw gateway.
If nil, will attempt to read from config file, then prompt."
  :type '(choice (const nil) string)
  :group 'openclaw)

(defcustom openclaw-gateway-password nil
  "Password for the OpenClaw gateway.
Used if token is not set."
  :type '(choice (const nil) string)
  :group 'openclaw)

(defcustom openclaw-config-file "~/.openclaw/openclaw.json"
  "Path to OpenClaw configuration file."
  :type 'string
  :group 'openclaw)

(defcustom openclaw-default-session "main"
  "Default session key to connect to."
  :type 'string
  :group 'openclaw)

(defcustom openclaw-session-buffer-name "*%s*"
  "Format string for session buffer names.
Default matches session key exactly, e.g. *agent:ceo_chryso:main*."
  :type 'string
  :group 'openclaw)

(defcustom openclaw-history-limit 200
  "Number of history messages to load."
  :type 'integer
  :group 'openclaw)

(defcustom openclaw-render-markdown t
  "Whether to render markdown-like formatting in message text."
  :type 'boolean
  :group 'openclaw)

(defcustom openclaw-inline-images t
  "Whether to attempt inline rendering of images/SVGs from message text."
  :type 'boolean
  :group 'openclaw)


;;; Faces

(defface openclaw-user-face
  '((t :foreground "cyan" :weight bold))
  "Face for user messages."
  :group 'openclaw)

(defface openclaw-assistant-face
  '((t :foreground "green"))
  "Face for assistant messages."
  :group 'openclaw)

(defface openclaw-system-face
  '((t :foreground "yellow" :slant italic))
  "Face for system messages."
  :group 'openclaw)

(defface openclaw-tool-face
  '((t :foreground "magenta"))
  "Face for tool output."
  :group 'openclaw)

(defface openclaw-timestamp-face
  '((t :foreground "gray60"))
  "Face for timestamps."
  :group 'openclaw)

(defface openclaw-session-header-face
  '((t :foreground "white" :weight bold :underline t))
  "Face for session headers."
  :group 'openclaw)

(defface openclaw-status-bar-face
  '((t :inherit mode-line :height 0.95))
  "Face for the separator/status line above the input box."
  :group 'openclaw)


;;; Variables

(defvar openclaw--websocket nil
  "Current websocket connection to the gateway.")

(defvar openclaw--request-id 0
  "Current request ID counter for JSON-RPC.")

(defvar openclaw--pending-requests (make-hash-table :test 'equal)
  "Hash table of pending request IDs to callbacks.")

(defvar openclaw--sessions (make-hash-table :test 'equal)
  "Hash table of session-key to session info.")

(defvar openclaw--agents nil
  "List of available agent info alists.")

(defvar openclaw--current-agent "main"
  "Currently active agent ID.")

(defvar openclaw--connect-nonce nil
  "Nonce from gateway connect challenge.")

(defvar openclaw--handshake-complete nil
  "Non-nil when gateway handshake is complete.")

(defvar openclaw--mode-line-string ""
  "String shown in mode-line for OpenClaw state.")

(defvar-local openclaw--current-session nil
  "Currently active session key (buffer-local).")

(defvar-local openclaw--session-label nil
  "Display label for current session (buffer-local).")

(defvar-local openclaw--message-history nil
  "List of recent messages for display (buffer-local).")

(defvar-local openclaw--input-start-marker nil
  "Marker for start of editable input area in chat buffer.")

(defvar-local openclaw--input-separator-marker nil
  "Marker for separator line before input area in chat buffer.")

(defvar-local openclaw--run-state 'idle
  "Current run state for this chat buffer: \\='idle or \\='thinking.")

(defvar-local openclaw--streaming-text ""
  "Accumulated streaming delta text for the current assistant turn.")

(defvar-local openclaw--streaming-marker nil
  "Marker pointing to the start of the streaming assistant message.")

(defvar-local openclaw--stream-finalized-p nil
  "Non-nil when streaming was just finalized.
Set by `openclaw--finalize-streaming', cleared by
`openclaw--handle-chat-message' to suppress the duplicate
chat.message insert that the gateway sends after streaming ends.")


;;; Reconnection

(defvar openclaw--reconnect-timer nil
  "Timer for pending reconnection attempt.")

(defvar openclaw--reconnect-attempts 0
  "Number of consecutive reconnection attempts.")

(defvar openclaw--reconnect-url nil
  "URL used for the last connection (used by auto-reconnect).")

(defvar openclaw--keepalive-timer nil
  "Timer for periodic keepalive pings.")

(defvar openclaw--keepalive-interval nil
  "Keepalive interval in seconds, derived from gateway tickIntervalMs.")

(defcustom openclaw-auto-reconnect t
  "Whether to automatically reconnect on dropped connections."
  :type 'boolean
  :group 'openclaw)

(defcustom openclaw-reconnect-max-attempts 10
  "Maximum number of consecutive reconnection attempts before giving up."
  :type 'integer
  :group 'openclaw)

(defcustom openclaw-reconnect-base-delay 1.0
  "Base delay in seconds for reconnection backoff."
  :type 'float
  :group 'openclaw)

(defcustom openclaw-reconnect-max-delay 60.0
  "Maximum delay in seconds for reconnection backoff."
  :type 'float
  :group 'openclaw)

(defcustom openclaw-keepalive t
  "Whether to send periodic keepalive pings during idle periods.
Uses the tickIntervalMs from the gateway handshake to determine interval."
  :type 'boolean
  :group 'openclaw)


;;; Keymaps

(defvar openclaw-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'openclaw-send-message)
    (define-key map (kbd "C-c C-c") #'openclaw-send-message)
    (define-key map (kbd "C-c C-l") #'openclaw-list-sessions)
    (define-key map (kbd "C-c C-s") #'openclaw-switch-session)
    (define-key map (kbd "C-c C-n") #'openclaw-new-chat)
    (define-key map (kbd "C-c C-a") #'openclaw-abort)
    (define-key map (kbd "C-c C-m") #'openclaw-model-picker)
    (define-key map (kbd "C-c C-p") #'openclaw-session-picker)
    (define-key map (kbd "C-c C-h") #'openclaw-show-history)
    (define-key map (kbd "C-c C-q") #'openclaw-close-connection)
    (define-key map (kbd "C-c C-t") #'openclaw-toggle-thinking)
    (define-key map (kbd "C-c C-o") #'openclaw-toggle-tool-output)
    (define-key map (kbd "C-c ?") #'openclaw-help)
    map)
  "Keymap for `openclaw-chat-mode'.")

(defvar openclaw-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'openclaw-send-message)
    (define-key map (kbd "C-c C-l") #'openclaw-list-sessions)
    (define-key map (kbd "C-c C-s") #'openclaw-switch-session)
    (define-key map (kbd "C-c C-n") #'openclaw-new-chat)
    (define-key map (kbd "C-c C-q") #'openclaw-close-connection)
    (define-key map (kbd "C-c C-h") #'openclaw-show-history)
    (define-key map (kbd "C-c ?") #'openclaw-help)
    ;; Leader-style single-letter bindings
    (define-key map (kbd "c") #'openclaw-connect)
    (define-key map (kbd "C") #'openclaw-close-connection)
    (define-key map (kbd "l") #'openclaw-list-sessions)
    (define-key map (kbd "s") #'openclaw-switch-session)
    (define-key map (kbd "n") #'openclaw-new-chat)
    (define-key map (kbd "m") #'openclaw-send-message)
    (define-key map (kbd "h") #'openclaw-show-history)
    (define-key map (kbd "?") #'openclaw-help)
    map)
  "Keymap for `openclaw-mode'.")


;;; Major Modes

(define-derived-mode openclaw-mode fundamental-mode "OpenClaw"
  "Major mode for OpenClaw interaction.
\\{openclaw-mode-map}"
  :group 'openclaw
  (buffer-disable-undo)
  (setq buffer-read-only t))

(define-derived-mode openclaw-chat-mode fundamental-mode "OpenClaw-Chat"
  "Major mode for chatting with OpenClaw sessions.
\\{openclaw-chat-mode-map}"
  :group 'openclaw
  (buffer-disable-undo)
  (setq-local openclaw--current-session nil)
  (setq-local openclaw--session-label nil)
  (setq-local openclaw--run-state 'idle)
  (openclaw--update-mode-line))


;;; Utilities

(defun openclaw--uuid ()
  "Generate a random UUID v4 string."
  (format "%04x%04x-%04x-%04x-%04x-%04x%04x%04x"
          (random 65535) (random 65535)
          (random 65535)
          (logior 16384 (random 4096))  ; version 4
          (logior 32768 (random 16384)) ; variant 1
          (random 65535) (random 65535) (random 65535)))

(defun openclaw--next-request-id ()
  "Generate the next request ID (UUID)."
  (openclaw--uuid))

(defun openclaw--idempotency-key ()
  "Generate idempotency key for chat.send requests."
  (openclaw--uuid))

(defun openclaw--read-config-token ()
  "Read gateway token from OpenClaw config file.
Returns token string or nil."
  (let ((config-path (expand-file-name openclaw-config-file)))
    (when (file-readable-p config-path)
      (condition-case nil
          (let* ((json-object-type 'alist)
                 (json-array-type 'vector)
                 (config (json-read-file config-path))
                 (gateway (alist-get 'gateway config))
                 (auth (alist-get 'auth gateway)))
            (alist-get 'token auth))
        (error nil)))))

(defun openclaw--effective-token ()
  "Return the effective gateway token.
Checks customization variable first, then config file."
  (or openclaw-gateway-token
      (openclaw--read-config-token)))

(defun openclaw--format-timestamp (ts)
  "Format timestamp TS for display.
TS can be a string (ISO 8601) or number (epoch ms)."
  (cond
   ((and (stringp ts) (string-match "T\\([0-9][0-9]:[0-9][0-9]\\)" ts))
    (format "[%s]" (match-string 1 ts)))
   ((numberp ts)
    (format-time-string "[%H:%M]" (seconds-to-time (/ ts 1000.0))))
   ((stringp ts)
    (format "[%s]" (substring ts 0 (min 16 (length ts)))))
   (t "")))


;;; Mode Line

(defun openclaw--update-mode-line ()
  "Update the mode-line string for OpenClaw."
  (setq openclaw--mode-line-string
        (if (openclaw-connected-p)
            (format " OC[%s/%s]"
                    openclaw--current-agent
                    (or openclaw--current-session openclaw-default-session))
          " OC[disconnected]")))


;;; WebSocket Communication

(defun openclaw--make-request (method &optional params callback)
  "Send a request frame with METHOD and PARAMS.
If CALLBACK is provided, it will be called with the response."
  (unless openclaw--websocket
    (error "Not connected to OpenClaw gateway"))
  (unless openclaw--handshake-complete
    (error "Gateway handshake not complete"))
  (let* ((id (openclaw--next-request-id))
         (request `((type . "req")
                    (id . ,id)
                    (method . ,method)
                    ,@(when params `((params . ,params))))))
    (when callback
      (puthash id callback openclaw--pending-requests))
    (websocket-send-text openclaw--websocket (json-encode request))
    id))

(defun openclaw--handle-response (response)
  "Handle a response frame from the gateway.
RESPONSE is the raw JSON string."
  (let* ((data (json-read-from-string response))
         (id (alist-get 'id data))
         (ok (alist-get 'ok data))
         (payload (alist-get 'payload data))
         (top-error (alist-get 'error data))
         (result (and (listp payload) (alist-get 'result payload)))
         (payload-error (and (listp payload) (alist-get 'error payload)))
         (callback (gethash id openclaw--pending-requests))
         (value (cond
                 ((and (assq 'ok data) (eq ok :json-false)) `((error . ,top-error)))
                 (top-error `((error . ,top-error)))
                 (payload-error `((error . ,payload-error)))
                 (result result)
                 (t payload))))
    (when callback
      (remhash id openclaw--pending-requests)
      (funcall callback value))))

(defun openclaw--send-connect ()
  "Send connect request after receiving challenge."
  (unless openclaw--connect-nonce
    (error "No nonce from gateway"))
  (let* ((token (openclaw--effective-token))
         (auth (cond
                (token `((token . ,token)))
                (openclaw-gateway-password
                 `((password . ,openclaw-gateway-password)))
                (t nil)))
         (id (openclaw--uuid))
         (params `((minProtocol . 3)
                   (maxProtocol . 3)
                   (client . ((id . "gateway-client")
                              (displayName . "openclaw.el")
                              (version . "0.2.0")
                              (platform . ,(symbol-name system-type))
                              (mode . "backend")))
                   (caps . [])
                   (role . "operator")
                   (scopes . ["operator.admin"])
                   ,@(when auth `((auth . ,auth)))))
         (connect-frame `((type . "req")
                          (id . ,id)
                          (method . "connect")
                          (params . ,params))))
    (puthash id (lambda (result)
                  (setq openclaw--handshake-complete t)
                  (message "Connected to OpenClaw gateway!")
                  ;; Extract tickIntervalMs for keepalive
                  (let* ((policy (and (listp result) (alist-get 'policy result)))
                         (tick-ms (and (listp policy) (alist-get 'tickIntervalMs policy))))
                    (when (and tick-ms (numberp tick-ms) (> tick-ms 0))
                      (setq openclaw--keepalive-interval (/ tick-ms 1000.0))
                      (openclaw--start-keepalive)))
                  (openclaw--update-mode-line)
                  (openclaw--fetch-sessions))
            openclaw--pending-requests)
    (websocket-send-text openclaw--websocket (json-encode connect-frame))))

(defun openclaw--handle-event (event)
  "Handle an EVENT notification from the gateway.
EVENT is the raw JSON string."
  (let* ((data (json-read-from-string event))
         (event-type (alist-get 'event data))
         (payload (alist-get 'payload data)))
    (pcase event-type
      ("connect.challenge"
       (let ((nonce (alist-get 'nonce payload)))
         (setq openclaw--connect-nonce nonce)
         (openclaw--send-connect)))
      ("chat"
       (openclaw--handle-chat-event payload))
      (_
       (let ((method (alist-get 'method data))
             (params (alist-get 'params data)))
         (pcase method
           ("chat.message" (openclaw--handle-chat-message params))
           ("sessions.update" (openclaw--handle-sessions-update params))
           (_ nil)))))))

(defun openclaw--on-message (_ws frame)
  "Handle incoming WebSocket message FRAME."
  (let ((payload (websocket-frame-payload frame)))
    (when (and payload (stringp payload) (> (length payload) 0))
      ;; Some gateway/tooling paths can emit non-JSON text frames. Ignore those.
      (if (not (string-match-p "\\`[[:space:]]*[\\[{]" payload))
          nil
        (condition-case err
            (let ((data (json-read-from-string payload)))
              (cond
               ;; Event frame (has 'event' key)
               ((alist-get 'event data)
                (openclaw--handle-event payload))
               ;; Response frame
               ((or (equal (alist-get 'type data) "res")
                    (alist-get 'payload data))
                (openclaw--handle-response payload))
               ;; Request frame (method-based events)
               ((alist-get 'method data)
                (openclaw--handle-event payload))
               (t nil)))
          (json-readtable-error nil)
          (error
           (message "OpenClaw parse error: %s" err)))))))

(defun openclaw--reconnect-delay ()
  "Compute delay for next reconnection attempt using bounded exponential backoff."
  (min openclaw-reconnect-max-delay
       (* openclaw-reconnect-base-delay
          (expt 2 (min openclaw--reconnect-attempts 10)))))

(defun openclaw--cancel-reconnect ()
  "Cancel any pending reconnection timer."
  (when openclaw--reconnect-timer
    (cancel-timer openclaw--reconnect-timer)
    (setq openclaw--reconnect-timer nil)))

(defun openclaw--schedule-reconnect ()
  "Schedule a reconnection attempt with exponential backoff."
  (openclaw--cancel-reconnect)
  (when (and openclaw-auto-reconnect
             openclaw--reconnect-url
             (< openclaw--reconnect-attempts openclaw-reconnect-max-attempts))
    (let ((delay (openclaw--reconnect-delay)))
      (message "OpenClaw: reconnecting in %.1fs (attempt %d/%d)..."
               delay
               (1+ openclaw--reconnect-attempts)
               openclaw-reconnect-max-attempts)
      (setq openclaw--reconnect-timer
            (run-at-time delay nil #'openclaw--attempt-reconnect)))))

(defun openclaw--attempt-reconnect ()
  "Attempt to reconnect to the gateway."
  (setq openclaw--reconnect-timer nil)
  (cl-incf openclaw--reconnect-attempts)
  (condition-case err
      (when openclaw--reconnect-url
        (openclaw-connect openclaw--reconnect-url))
    (error
     (message "OpenClaw: reconnect failed: %s" err)
     (openclaw--schedule-reconnect))))

(defun openclaw--reset-all-streaming-state ()
  "Reset stale streaming state in all chat buffers.
Called on disconnect or reconnect to prevent stale markers/text
from corrupting the display after a mid-stream connection drop."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and (eq major-mode 'openclaw-chat-mode)
                 (or (not (string-empty-p (or openclaw--streaming-text "")))
                     openclaw--streaming-marker))
        (let ((inhibit-read-only t))
          ;; If we were mid-stream, add a truncation notice
          (when (and openclaw--streaming-marker
                     (marker-buffer openclaw--streaming-marker))
            (save-excursion
              (goto-char openclaw--streaming-marker)
              (insert (propertize " [interrupted]" 'face 'openclaw-system-face))
              (insert "\n")
              ;; Advance separator marker past the interrupted text
              (when (and openclaw--input-separator-marker
                         (marker-buffer openclaw--input-separator-marker))
                (set-marker openclaw--input-separator-marker (point)))))
          ;; Clean up streaming state
          (when openclaw--streaming-marker
            (set-marker openclaw--streaming-marker nil))
          (setq-local openclaw--streaming-marker nil)
          (setq-local openclaw--streaming-text "")
          (setq-local openclaw--stream-finalized-p nil)
          (setq-local openclaw--run-state 'idle)
          (openclaw--refresh-status-bar))))))

(defun openclaw--cancel-keepalive ()
  "Cancel the keepalive timer if running."
  (when openclaw--keepalive-timer
    (cancel-timer openclaw--keepalive-timer)
    (setq openclaw--keepalive-timer nil)))

(defun openclaw--start-keepalive ()
  "Start periodic keepalive pings if enabled and interval is known."
  (openclaw--cancel-keepalive)
  (when (and openclaw-keepalive
             openclaw--keepalive-interval
             (> openclaw--keepalive-interval 0))
    (setq openclaw--keepalive-timer
          (run-at-time openclaw--keepalive-interval
                       openclaw--keepalive-interval
                       #'openclaw--send-keepalive))))

(defun openclaw--send-keepalive ()
  "Send a lightweight ping to the gateway to keep the connection alive."
  (when (and openclaw--websocket
             openclaw--handshake-complete
             (openclaw-connected-p))
    (condition-case nil
        (websocket-send-text
         openclaw--websocket
         (json-encode `((type . "req")
                        (id . ,(openclaw--uuid))
                        (method . "ping"))))
      (error
       ;; Connection probably died; cancel keepalive, let reconnect handle it
       (openclaw--cancel-keepalive)))))

(defun openclaw--on-close (_ws)
  "Handle WebSocket close event."
  (message "OpenClaw connection closed")
  ;; Reset streaming state in all buffers before clearing connection
  (openclaw--reset-all-streaming-state)
  (openclaw--cancel-keepalive)
  (setq openclaw--websocket nil
        openclaw--handshake-complete nil)
  (openclaw--update-mode-line)
  ;; Auto-reconnect if enabled and we have a URL
  (openclaw--schedule-reconnect))

(defun openclaw--on-error (_ws err)
  "Handle WebSocket error ERR."
  (message "OpenClaw connection error: %s" err))

(defun openclaw--on-open (ws)
  "Handle WebSocket open event for WS."
  (setq openclaw--websocket ws
        openclaw--connect-nonce nil
        openclaw--handshake-complete nil
        openclaw--reconnect-attempts 0)
  (openclaw--cancel-reconnect)
  ;; Reset any stale streaming state from prior connection
  (openclaw--reset-all-streaming-state))


;;; Connection Management

;;;###autoload
(defun openclaw-connect (&optional url)
  "Connect to OpenClaw gateway at URL.
If URL is nil, use `openclaw-gateway-url'."
  (interactive)
  (setq url (or url openclaw-gateway-url))
  (when openclaw--websocket
    (let ((openclaw-auto-reconnect nil)) ; suppress reconnect on intentional close
      (openclaw-close-connection)))

  (setq openclaw--reconnect-url url)
  (message "Connecting to OpenClaw at %s..." url)

  (let ((ws (websocket-open
             url
             :on-open #'openclaw--on-open
             :on-message #'openclaw--on-message
             :on-close #'openclaw--on-close
             :on-error #'openclaw--on-error)))
    (setq openclaw--websocket ws)))

(defun openclaw-close-connection ()
  "Close the connection to OpenClaw gateway."
  (interactive)
  (openclaw--cancel-reconnect)
  (openclaw--cancel-keepalive)
  (openclaw--reset-all-streaming-state)
  (setq openclaw--reconnect-url nil)  ; prevent auto-reconnect on explicit close
  (when openclaw--websocket
    (websocket-close openclaw--websocket)
    (setq openclaw--websocket nil
          openclaw--handshake-complete nil)
    (openclaw--update-mode-line)
    (message "Disconnected from OpenClaw")))

(defun openclaw-connected-p ()
  "Return non-nil if connected to gateway."
  (and openclaw--websocket
       (condition-case nil
           (websocket-openp openclaw--websocket)
         (error nil))))


;;; Session Management

(defun openclaw--fetch-sessions ()
  "Fetch the list of sessions from the gateway."
  (when (and (openclaw-connected-p) openclaw--handshake-complete)
    (openclaw--make-request
     "sessions.list"
     '((limit . 50))
     (lambda (result)
       (clrhash openclaw--sessions)
       (let* ((sessions-raw (alist-get 'sessions result))
              (sessions (if (vectorp sessions-raw)
                            (append sessions-raw nil)
                          (when sessions-raw (list sessions-raw)))))
         (dolist (session sessions)
           (let ((key (alist-get 'key session)))
             (when key
               (puthash key session openclaw--sessions))))
         (message "Loaded %d OpenClaw sessions" (hash-table-count openclaw--sessions)))))))

(defun openclaw-list-sessions ()
  "Display list of OpenClaw sessions."
  (interactive)
  (if (not (openclaw-connected-p))
      (message "Not connected to OpenClaw")
    (openclaw--make-request
     "sessions.list"
     '((limit . 50))
     (lambda (result)
       (let ((buf (get-buffer-create "*openclaw-sessions*")))
         (with-current-buffer buf
           (setq buffer-read-only nil)
           (erase-buffer)
           (insert (propertize "OpenClaw Sessions\n" 'face 'openclaw-session-header-face))
           (insert "=================\n\n")
           (let* ((sessions-raw (alist-get 'sessions result))
                  (sessions (if (vectorp sessions-raw) (append sessions-raw nil) sessions-raw)))
             (if (null sessions)
                 (insert "No sessions found.\n")
               (dolist (session sessions)
                 (let* ((key (alist-get 'key session))
                        (label (or (alist-get 'label session)
                                  (alist-get 'displayName session)
                                  key))
                        (agent (or (alist-get 'agentId session) "?")))
                   (insert-button label
                                 'action (lambda (_) (openclaw--switch-to-session key))
                                 'follow-link t)
                   (insert (format " [agent:%s]\n" agent))))))
           (setq buffer-read-only t)
           (goto-char (point-min))
           (display-buffer buf)))))))

(defun openclaw--switch-to-session (session-key)
  "Switch to or create buffer for SESSION-KEY."
  (let* ((session-info (gethash session-key openclaw--sessions))
         (display-name (or (and session-info
                                (or (alist-get 'label session-info)
                                    (alist-get 'displayName session-info)))
                           session-key))
         ;; Buffer name must mirror session identifier used in switch picker.
         (buf-name (format openclaw-session-buffer-name session-key))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (unless (eq major-mode 'openclaw-chat-mode)
        (openclaw-chat-mode))
      (setq-local openclaw--current-session session-key)
      (setq-local openclaw--session-label session-key)
      (setq-local openclaw--run-state 'idle)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "Session: %s" session-key)
                            'face 'openclaw-session-header-face))
        (when (and display-name (not (equal display-name session-key)))
          (insert (format " (%s)" display-name)))
        (insert "\n")
        (insert "Loading history...\n\n"))
      (openclaw--update-mode-line))
    (switch-to-buffer buf)
    (when openclaw--handshake-complete
      (openclaw--fetch-history session-key))))

(defun openclaw-switch-session ()
  "Interactively switch to an OpenClaw session."
  (interactive)
  (if (hash-table-empty-p openclaw--sessions)
      (message "No sessions available. Connect first.")
    (let* ((sessions (hash-table-keys openclaw--sessions))
           (choice (completing-read "Session: " sessions nil t)))
      (openclaw--switch-to-session choice))))

(defun openclaw-session-picker ()
  "Pick a session interactively (TUI Ctrl+P equivalent)."
  (interactive)
  (openclaw-switch-session))

(defun openclaw-new-chat ()
  "Start a new chat session."
  (interactive)
  (let ((buf (generate-new-buffer (format openclaw-session-buffer-name "new"))))
    (with-current-buffer buf
      (openclaw-chat-mode)
      (let ((inhibit-read-only t))
        (insert (propertize "Welcome to OpenClaw!\n" 'face 'openclaw-session-header-face))
        (insert "Type your message in the input box and press C-c C-c to send.\n"))
      (openclaw--insert-input-area ""))
    (switch-to-buffer buf)
    (goto-char (point-max))))


;;; Agent Management

(defun openclaw-list-agents ()
  "List available agents."
  (interactive)
  (if (not (openclaw-connected-p))
      (message "Not connected to OpenClaw")
    (openclaw--make-request
     "agents.list"
     nil
     (lambda (result)
       (let* ((agents-raw (or (alist-get 'agents result) result))
              (agents (if (vectorp agents-raw) (append agents-raw nil) agents-raw)))
         (setq openclaw--agents agents)
         (let ((buf (get-buffer-create "*openclaw-agents*")))
           (with-current-buffer buf
             (setq buffer-read-only nil)
             (erase-buffer)
             (insert (propertize "OpenClaw Agents\n" 'face 'openclaw-session-header-face))
             (insert "===============\n\n")
             (if (null agents)
                 (insert "No agents found.\n")
               (dolist (agent agents)
                 (let ((id (or (alist-get 'id agent)
                              (alist-get 'agentId agent)
                              "unknown")))
                   (insert-button id
                                 'action (lambda (_) (openclaw-switch-agent id))
                                 'follow-link t)
                   (insert "\n"))))
             (setq buffer-read-only t)
             (goto-char (point-min)))
           (display-buffer buf)))))))

(defun openclaw-switch-agent (agent-id)
  "Switch to AGENT-ID."
  (interactive "sAgent ID: ")
  (setq openclaw--current-agent agent-id)
  (openclaw--update-mode-line)
  (openclaw--fetch-sessions)
  (message "Switched to agent: %s" agent-id))


;;; Chat Functions

(defun openclaw--oct-digit-p (ch)
  "Return non-nil if CH is an octal digit character code."
  (and (integerp ch) (>= ch ?0) (<= ch ?7)))

(defun openclaw--decode-octal-escapes (s)
  "Decode octal byte escapes in string S (e.g. \\342\\200\\231) as UTF-8."
  (let* ((len (length s))
         (i 0)
         (bytes '())
         (changed nil))
    (while (< i len)
      (let ((c (aref s i)))
        (if (and (= c ?\\)
                 (<= (+ i 3) (1- len))
                 (openclaw--oct-digit-p (aref s (1+ i)))
                 (openclaw--oct-digit-p (aref s (+ i 2)))
                 (openclaw--oct-digit-p (aref s (+ i 3))))
            (progn
              (push (string-to-number (substring s (1+ i) (+ i 4)) 8) bytes)
              (setq i (+ i 4)
                    changed t))
          (push c bytes)
          (setq i (1+ i)))))
    (if (not changed)
        s
      (condition-case nil
          (decode-coding-string (apply #'unibyte-string (nreverse bytes)) 'utf-8 t)
        (error s)))))

(defun openclaw--normalize-text (s)
  "Normalize string S for display."
  (if (not (stringp s))
      ""
    (let ((out (openclaw--decode-octal-escapes s)))
      (when (and (stringp out) (not (multibyte-string-p out)))
        (setq out
              (condition-case nil
                  (decode-coding-string out 'utf-8 t)
                (error out))))
      out)))

(defun openclaw--content->text (content)
  "Convert CONTENT payload into displayable text."
  (cond
   ((stringp content) (openclaw--normalize-text content))
   ;; CONTENT as a single part object: ((type . "text") (text . "..."))
   ((and (listp content)
         (or (alist-get 'type content) (alist-get 'text content)))
    (let ((ptext (alist-get 'text content)))
      (if (stringp ptext) (openclaw--normalize-text ptext) "")))
   ;; CONTENT as list of parts
   ((listp content)
    (mapconcat #'openclaw--content->text content "\n"))
   ((vectorp content)
    (mapconcat #'openclaw--content->text (append content nil) "\n"))
   (t "")))

(defun openclaw--role-face (role)
  "Return the face for message ROLE."
  (let ((r (if (symbolp role) (symbol-name role) role)))
    (pcase r
      ("user" 'openclaw-user-face)
      ("assistant" 'openclaw-assistant-face)
      ("system" 'openclaw-system-face)
      ("tool" 'openclaw-tool-face)
      (_ 'default))))

(defun openclaw--agent-from-session-key (session-key)
  "Extract agent id from SESSION-KEY like agent:ceo_chryso:main."
  (when (and (stringp session-key)
             (string-match "^agent:\\([^:]+\\):" session-key))
    (match-string 1 session-key)))

(defun openclaw--role-label (role &optional session-key)
  "Return display label for ROLE.
For assistant messages, prefer agent name from SESSION-KEY."
  (let ((r (if (symbolp role) (symbol-name role) role)))
    (pcase r
      ("user" "You")
      ("assistant" (or (openclaw--agent-from-session-key session-key)
                        openclaw--current-agent
                        "Assistant"))
      ("system" "System")
      ("tool" "Tool")
      (_ (capitalize (format "%s" r))))))

(defun openclaw--heartbeat-text-p (text)
  "Return non-nil if TEXT looks like heartbeat content."
  (and (stringp text)
       (string-match-p "\\bHEARTBEAT_" text)))

(defun openclaw--status-bar-text ()
  "Return status text shown in the separator bar above input box."
  (format " %s | %s | agent:%s | session:%s | send: RET / C-c C-c "
          (if (openclaw-connected-p) "connected" "disconnected")
          (pcase openclaw--run-state
            ('thinking "thinking")
            (_ "idle"))
          (or openclaw--current-agent "?")
          (or openclaw--current-session "?")))

(defun openclaw--refresh-status-bar ()
  "Refresh the status line above the input box in current chat buffer."
  (when (and (eq major-mode 'openclaw-chat-mode)
             openclaw--input-separator-marker
             (marker-buffer openclaw--input-separator-marker))
    (let ((inhibit-read-only t)
          (status (openclaw--status-bar-text)))
      (save-excursion
        (goto-char openclaw--input-separator-marker)
        (let ((beg (line-beginning-position))
              (end (line-end-position)))
          (delete-region beg end)
          (goto-char beg)
          (insert (propertize status 'face 'openclaw-status-bar-face))
          (set-marker openclaw--input-separator-marker beg))))))

(defun openclaw--insert-markdown-text (text)
  "Insert TEXT with lightweight markdown styling."
  (let ((start (point)))
    (insert (or text ""))
    (when openclaw-render-markdown
      (save-excursion
        (save-restriction
          (narrow-to-region start (point))
          ;; Simple inline code: `...`
          (goto-char (point-min))
          (while (search-forward "`" nil t)
            (let ((code-start (point)))
              (when (search-forward "`" nil t)
                (add-face-text-property code-start (1- (point))
                                        'font-lock-constant-face t))))
          ;; Simple bold: **...**
          (goto-char (point-min))
          (while (search-forward "**" nil t)
            (let ((bold-start (point)))
              (when (search-forward "**" nil t)
                (add-face-text-property bold-start (- (point) 2)
                                        'bold t))))
          ;; Fenced code blocks: ```...```
          (goto-char (point-min))
          (while (search-forward "```" nil t)
            (let ((block-start (point)))
              (when (search-forward "```" nil t)
                (add-face-text-property block-start (- (point) 3)
                                        'font-lock-comment-face t)))))))))

(defun openclaw--insert-inline-images-from-text (text)
  "Try to render inline images referenced in TEXT.
Supports markdown image links and direct image URLs (png/jpg/jpeg/gif/webp/svg)."
  (when (and openclaw-inline-images (display-images-p) (stringp text))
    (let ((case-fold-search t)
          (urls '()))
      ;; Markdown images: ![alt](url)
      (save-match-data
        (let ((pos 0))
          (while (string-match "!\\[[^]]*\\](\\([^()]+\\))" text pos)
            (push (match-string 1 text) urls)
            (setq pos (match-end 0)))))
      ;; Direct URLs
      (save-match-data
        (let ((pos 0))
          (while (string-match "\\(https?://[^[:space:]\\n]+\\.\\(png\\|jpe?g\\|gif\\|webp\\|svg\\)\\)" text pos)
            (push (match-string 1 text) urls)
            (setq pos (match-end 1)))))
      (dolist (url (delete-dups (nreverse urls)))
        (condition-case nil
            (let ((img (if (string-match-p "\\.svg\\(?:$\\|[?#]\\)" url)
                           (create-image url 'svg nil)
                         (create-image url nil nil))))
              (when img
                (insert "\n")
                (insert-image img)
                (insert "\n")))
          (error nil))))))

(defun openclaw--insert-rendered-content (content-text)
  "Insert CONTENT-TEXT with markdown, heartbeat styling and inline images."
  (let ((start (point)))
    (openclaw--insert-markdown-text content-text)
    (when (openclaw--heartbeat-text-p content-text)
      (add-face-text-property start (point) 'font-lock-comment-face t))
    (openclaw--insert-inline-images-from-text content-text)))

(defun openclaw--input-text ()
  "Return current draft text from chat input area."
  (if (and openclaw--input-start-marker
           (marker-buffer openclaw--input-start-marker))
      (buffer-substring-no-properties openclaw--input-start-marker (point-max))
    ""))

(defun openclaw--insert-input-area (&optional draft)
  "Insert chat input area separator and editable box.
Optional DRAFT pre-fills the input box."
  (let ((status (openclaw--status-bar-text)))
    (insert "\n")
    ;; Keep separator marker fixed at start of status bar.
    (setq openclaw--input-separator-marker (copy-marker (point) nil))
    (insert (propertize status 'face 'openclaw-status-bar-face))
    (insert "\n")
    (insert (propertize (make-string (max 10 (length status)) ?-)
                        'face 'openclaw-status-bar-face))
    (insert "\n")
    (insert (propertize "Message:\n" 'face 'openclaw-timestamp-face))
    ;; Keep marker at beginning of input area as user types.
    (setq openclaw--input-start-marker (copy-marker (point) nil))
    (when draft (insert draft))))

(defun openclaw--insert-message-before-input (prefix prefix-face content)
  "Insert a chat message line before input area.
PREFIX uses PREFIX-FACE, followed by CONTENT text.
Advances `openclaw--input-separator-marker' past inserted text so
that `openclaw--refresh-status-bar' does not overwrite the message."
  (let ((inhibit-read-only t)
        (insert-pos (if (and openclaw--input-separator-marker
                             (marker-buffer openclaw--input-separator-marker))
                        (marker-position openclaw--input-separator-marker)
                      (point-max))))
    (save-excursion
      (goto-char insert-pos)
      (insert (propertize prefix 'face prefix-face))
      (let ((content-start (point)))
        (openclaw--insert-rendered-content content)
        (when (= content-start (point))
          (insert "")))
      (insert "\n")
      ;; Advance separator marker past the newly inserted text.
      (when (and openclaw--input-separator-marker
                 (marker-buffer openclaw--input-separator-marker))
        (set-marker openclaw--input-separator-marker (point))))))

(defun openclaw--fetch-history (session-key)
  "Fetch chat history for SESSION-KEY."
  (when openclaw--handshake-complete
    (openclaw--make-request
     "chat.history"
     `((sessionKey . ,session-key)
       (limit . ,openclaw-history-limit))
     (lambda (result)
       (let ((target-buf nil))
         (dolist (buf (buffer-list))
           (with-current-buffer buf
             (when (and (eq major-mode 'openclaw-chat-mode)
                        (equal openclaw--current-session session-key))
               (setq target-buf buf))))
         (when target-buf
           (with-current-buffer target-buf
             (let* ((messages-raw (alist-get 'messages result))
                  (messages (if (vectorp messages-raw)
                                (append messages-raw nil)
                              messages-raw))
                  (draft (openclaw--input-text))
                  (inhibit-read-only t))
             (erase-buffer)
             (when openclaw--session-label
               (insert (propertize (format "Session: %s\n\n"
                                           openclaw--session-label)
                                   'face 'openclaw-session-header-face)))
             (if (or (not messages) (null messages))
                 (progn
                   (setq-local openclaw--run-state 'idle)
                   (insert "No messages yet. Press C-c C-c to send a message.\n"))
               (let ((last-role nil))
                 (dolist (msg messages)
                   (let* ((role (alist-get 'role msg))
                          (timestamp (alist-get 'timestamp msg))
                          (content-text (openclaw--content->text
                                         (alist-get 'content msg)))
                          (ts-str (openclaw--format-timestamp timestamp))
                          (role-label (openclaw--role-label role session-key))
                          (role-face (openclaw--role-face role)))
                     (setq last-role role)
                     (insert (propertize ts-str 'face 'openclaw-timestamp-face))
                     (insert " ")
                     (insert (propertize (format "%s: " role-label)
                                         'face role-face))
                     (openclaw--insert-rendered-content content-text)
                     (insert "\n")))
                 ;; Infer state from last visible role.
                 (setq-local openclaw--run-state
                             (if (equal (format "%s" last-role) "user")
                                 'thinking
                               'idle))))
             (openclaw--insert-input-area draft)
             (goto-char (point-max))))))))))

(defmacro openclaw--dispatch-to-session-buffer (session-key &rest body)
  "Execute BODY in the first chat buffer matching SESSION-KEY."
  (declare (indent 1))
  `(cl-dolist (buf (buffer-list))
     (with-current-buffer buf
       (when (and (eq major-mode 'openclaw-chat-mode)
                  (equal openclaw--current-session ,session-key))
         ,@body
         (cl-return)))))

(defun openclaw--handle-chat-event (payload)
  "Handle a chat event PAYLOAD incrementally.
Processes state=delta for streaming, state=final for completion,
state=error for errors.  Only falls back to full history fetch
when no state field is present (legacy events)."
  (let* ((session-key (or (alist-get 'sessionKey payload)
                          (alist-get 'session_key payload)))
         (state (alist-get 'state payload))
         (delta-text (alist-get 'delta payload))
         (content-text (openclaw--content->text (alist-get 'content payload)))
         (error-msg (alist-get 'error payload)))
    (when (and (stringp session-key) (> (length session-key) 0))
      (pcase state
        ("delta"
         ;; Streaming delta: append text incrementally to buffer
         (openclaw--append-streaming-delta session-key (or delta-text content-text "")))
        ("final"
         ;; Streaming complete: finalize the streamed message
         (openclaw--finalize-streaming session-key content-text))
        ("error"
         ;; Error during streaming — finalize and show error in one pass
         (let ((err-text (format "%s" (or error-msg "Unknown streaming error"))))
           (openclaw--dispatch-to-session-buffer session-key
             ;; Reset streaming state inline
             (let ((inhibit-read-only t))
               (when openclaw--streaming-marker
                 (save-excursion
                   (goto-char openclaw--streaming-marker)
                   (insert "\n"))
                 (set-marker openclaw--streaming-marker nil))
               (setq-local openclaw--streaming-text "")
               (setq-local openclaw--streaming-marker nil))
             ;; Insert error message
             (openclaw--insert-message-before-input
              "Error: " 'openclaw-system-face err-text)
             (setq-local openclaw--run-state 'idle)
             (openclaw--refresh-status-bar))))
        (_
         ;; Legacy event without state field — fall back to history fetch
         (openclaw--fetch-history session-key))))))

(defun openclaw--append-streaming-delta (session-key text)
  "Append streaming delta TEXT to the chat buffer for SESSION-KEY."
  (cl-dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and (eq major-mode 'openclaw-chat-mode)
                 (equal openclaw--current-session session-key))
        (let ((inhibit-read-only t))
          ;; First delta — insert the role label and set up marker.
          ;; Keep the status bar on its own following line so refreshes
          ;; cannot overwrite the streamed assistant text.
          (when (string-empty-p (or openclaw--streaming-text ""))
            (setq-local openclaw--run-state 'thinking)
            (openclaw--refresh-status-bar)
            (let ((insert-pos (if (and openclaw--input-separator-marker
                                       (marker-buffer openclaw--input-separator-marker))
                                  (marker-position openclaw--input-separator-marker)
                                (point-max)))
                  (role-label (openclaw--role-label "assistant" session-key)))
              (save-excursion
                (goto-char insert-pos)
                (insert (propertize (format "%s: " role-label)
                                    'face 'openclaw-assistant-face))
                (let ((stream-pos (point)))
                  ;; Reserve a newline now; deltas are inserted before it.
                  (insert "\n")
                  (setq-local openclaw--streaming-marker
                              (copy-marker stream-pos t))
                  (when (and openclaw--input-separator-marker
                             (marker-buffer openclaw--input-separator-marker))
                    ;; Marker now points to the start of the status bar line.
                    (set-marker openclaw--input-separator-marker (point)))))))
          ;; Append the delta text at the streaming marker.
          (when (and openclaw--streaming-marker
                     (marker-buffer openclaw--streaming-marker))
            (save-excursion
              (goto-char openclaw--streaming-marker)
              (insert (openclaw--normalize-text text))
              (set-marker openclaw--streaming-marker (point))))
          (setq-local openclaw--streaming-text
                      (concat (or openclaw--streaming-text "") text)))
        (cl-return)))))

(defun openclaw--finalize-streaming (session-key final-text)
  "Finalize streaming for SESSION-KEY.
If FINAL-TEXT is non-nil, replace the streamed content with it."
  (cl-dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and (eq major-mode 'openclaw-chat-mode)
                 (equal openclaw--current-session session-key))
        (let ((inhibit-read-only t))
          ;; If we never got a delta (no streaming marker), insert the final text
          (if (or (not openclaw--streaming-marker)
                  (not (marker-buffer openclaw--streaming-marker)))
              (when (and final-text (not (string-empty-p final-text)))
                (openclaw--insert-message-before-input
                 (format "%s: " (openclaw--role-label "assistant" session-key))
                 'openclaw-assistant-face
                 final-text))
            ;; Streaming was in progress.
            ;; Newline before the status bar was already inserted when
            ;; streaming started, so no extra insertion is needed here.
            nil)
          ;; Reset streaming state and mark as just-finalized so that
          ;; the redundant chat.message event is suppressed.
          (setq-local openclaw--streaming-text "")
          (when openclaw--streaming-marker
            (set-marker openclaw--streaming-marker nil))
          (setq-local openclaw--streaming-marker nil)
          (setq-local openclaw--stream-finalized-p t)
          (setq-local openclaw--run-state 'idle)
          (openclaw--refresh-status-bar))
        (cl-return)))))

(defun openclaw--handle-chat-message (params)
  "Handle incoming chat message PARAMS.
Suppresses the insert when the message is an assistant reply that
was already rendered via streaming (detected by the
`openclaw--stream-finalized-p' flag)."
  (let* ((session-key (alist-get 'sessionKey params))
         (role (alist-get 'role params))
         (content-text (openclaw--content->text (alist-get 'content params)))
         (role-label (openclaw--role-label role session-key))
         (role-face (openclaw--role-face role)))
    (cl-dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (and (eq major-mode 'openclaw-chat-mode)
                   (equal openclaw--current-session session-key))
          ;; If streaming just finalized an assistant message, this
          ;; chat.message is a duplicate — suppress it.
          (if (and openclaw--stream-finalized-p
                   (equal (format "%s" role) "assistant"))
              (setq-local openclaw--stream-finalized-p nil)
            ;; Normal (non-streamed) message — insert it.
            (openclaw--insert-message-before-input
             (format "%s: " role-label)
             role-face
             content-text)
            (setq-local openclaw--run-state
                        (if (equal (format "%s" role) "user")
                            'thinking
                          'idle))
            (openclaw--refresh-status-bar))
          (cl-return))))))

(defun openclaw--handle-sessions-update (_params)
  "Handle sessions update notification."
  (openclaw--fetch-sessions))

(defun openclaw-send-message ()
  "Send message from the chat input box (below separator)."
  (interactive)
  (unless (eq major-mode 'openclaw-chat-mode)
    (error "Not in an OpenClaw chat buffer"))
  (unless openclaw--current-session
    (error "No active session"))
  (unless (and openclaw--input-start-marker
               (marker-buffer openclaw--input-start-marker))
    (error "Input box not ready yet"))

  (let* ((raw (buffer-substring-no-properties openclaw--input-start-marker (point-max)))
         (msg (string-trim raw)))
    (when (string-empty-p msg)
      (error "Input box is empty"))

    ;; Clear input box first.
    (let ((inhibit-read-only t))
      (delete-region openclaw--input-start-marker (point-max)))

    ;; Insert user message into history area.
    (openclaw--insert-message-before-input "You: " 'openclaw-user-face msg)
    (setq-local openclaw--run-state 'thinking)
    (openclaw--refresh-status-bar)

    ;; Send to gateway.
    (openclaw--make-request
     "chat.send"
     `((sessionKey . ,openclaw--current-session)
       (message . ,msg)
       (idempotencyKey . ,(openclaw--idempotency-key)))
     (lambda (result)
       (when (and result (listp result) (alist-get 'error result))
         (setq-local openclaw--run-state 'idle)
         (openclaw--refresh-status-bar)
         (message "Send error: %s" (alist-get 'error result)))))

    (goto-char (point-max))))

(defun openclaw-show-history ()
  "Show/refresh chat history for current session."
  (interactive)
  (when openclaw--current-session
    (openclaw--fetch-history openclaw--current-session)))


;;; Slash Commands

(defun openclaw-slash-command (cmd)
  "Execute slash command CMD in current session."
  (interactive "sCommand: ")
  (unless (string-prefix-p "/" cmd)
    (setq cmd (concat "/" cmd)))
  (openclaw--make-request
   "chat.send"
   `((sessionKey . ,openclaw--current-session)
     (message . ,cmd)
     (idempotencyKey . ,(openclaw--idempotency-key)))
   (lambda (_result)
     (message "Command sent: %s" cmd))))

(defun openclaw-abort ()
  "Abort the current agent run."
  (interactive)
  (if openclaw--current-session
      (openclaw-slash-command "/abort")
    (message "No active session")))

(defun openclaw-model-picker ()
  "Pick a model (TUI Ctrl+L equivalent)."
  (interactive)
  (if (not (openclaw-connected-p))
      (message "Not connected to OpenClaw")
    (openclaw--make-request
     "models.list"
     nil
     (lambda (result)
       (let* ((models-raw (or (alist-get 'models result) result))
              (models (if (vectorp models-raw) (append models-raw nil) models-raw))
              (names (mapcar (lambda (m)
                              (or (alist-get 'id m)
                                  (alist-get 'name m)
                                  (format "%s" m)))
                            models)))
         (if (null names)
             (message "No models available")
           (let ((choice (completing-read "Model: " names nil t)))
             (when openclaw--current-session
               (openclaw-slash-command (format "/model %s" choice))))))))))

(defun openclaw-toggle-thinking ()
  "Toggle thinking visibility (TUI Ctrl+T equivalent)."
  (interactive)
  (openclaw-slash-command "/think"))

(defun openclaw-toggle-tool-output ()
  "Toggle tool output expansion (TUI Ctrl+O equivalent)."
  (interactive)
  (message "Tool output toggle: not yet implemented for Emacs"))


;;; Help

(defun openclaw-help ()
  "Show OpenClaw help."
  (interactive)
  (let ((help-buf (get-buffer-create "*openclaw-help*")))
    (with-current-buffer help-buf
      (setq buffer-read-only nil)
      (erase-buffer)
      (insert "OpenClaw Emacs Interface Help
================================

Quick Start:
  M-x openclaw-connect     - Connect to gateway
  M-x openclaw-chat        - Start a new chat
  M-x openclaw-list-sessions - List available sessions

Chat Mode Keybindings:
  RET / C-c C-c  - Send message
  C-c C-l        - List sessions
  C-c C-s        - Switch session
  C-c C-n        - New chat
  C-c C-a        - Abort current run
  C-c C-m        - Model picker
  C-c C-p        - Session picker
  C-c C-h        - Show/refresh history
  C-c C-t        - Toggle thinking
  C-c C-o        - Toggle tool output
  C-c C-q        - Close connection
  C-c ?          - This help

Slash Commands (type in chat):
  /help          - Show gateway help
  /status        - Show session status
  /agent <id>    - Switch agent
  /agents        - List agents
  /session <key> - Switch session
  /sessions      - List sessions
  /model <m>     - Change model
  /models        - List models
  /new           - Reset session
  /abort         - Abort current run
  /deliver <on|off> - Toggle delivery
  /think <level> - Set thinking level
  /verbose <on|off> - Set verbose mode
  /context       - Show context info
  /exit          - Exit/disconnect
")
      (setq buffer-read-only t)
      (goto-char (point-min)))
    (display-buffer help-buf)))


;;; Entry Points

;;;###autoload
(defun openclaw-chat ()
  "Start chatting with OpenClaw."
  (interactive)
  (unless (openclaw-connected-p)
    (openclaw-connect))
  (openclaw-new-chat))

;;;###autoload
(defalias 'openclaw 'openclaw-connect
  "Connect to OpenClaw gateway.")

(provide 'openclaw)

;;; openclaw.el ends here
