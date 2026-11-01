# shellcheck shell=bash
#
# big-mount user interface: the same content in a GTK 4 dialog (dialog.py, the
# look of the application, on any desktop) or in a terminal, plus desktop
# notifications.
#
# Content is built as a small document (bm_doc_*), so that untrusted text
# (volume labels, file and process names) reaches each backend as data, and no
# markup ends up in translatable strings. Nothing here ever runs as root: the
# dialogs belong to the user session.

bm_ui_init() {
   BM_UI="${BM_UI:-}"
   if [ -z "$BM_UI" ]; then
      BM_UI="tty"
      if [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ] && [ "$EUID" -ne 0 ] \
         && { [ -n "${BM_DIALOG_PROGRAM:-}" ] || { command -v python3 >/dev/null && [ -r "$BM_LIB_DIR/dialog.py" ]; }; }; then
         BM_UI=gtk
      fi
   fi
   BM_APP_NAME="Big-Mount"
}

# ----- document builder ------------------------------------------------------
# Kinds: h (heading), p (paragraph), kv (key/value), li (list item),
# th/tr (table header/row, cells separated by a TAB), pre (technical text).

bm_doc_new() { DOC_KIND=() DOC_TEXT=(); }
bm_doc_h()   { DOC_KIND+=(h)   DOC_TEXT+=("$1"); }
bm_doc_p()   { DOC_KIND+=(p)   DOC_TEXT+=("$1"); }
bm_doc_kv()  { DOC_KIND+=(kv)  DOC_TEXT+=("$1"$'\t'"$2"); }
bm_doc_li()  { DOC_KIND+=(li)  DOC_TEXT+=("$1"); }
# Table cells may hold a second, smaller line after a newline; it is kept as
# \x1f inside the row because rows are split with `read`.
bm_doc_th()  { local IFS=$'\t' r; r="$*"; DOC_KIND+=(th) DOC_TEXT+=("${r//$'\n'/$'\x1f'}"); }
bm_doc_tr()  { local IFS=$'\t' r; r="$*"; DOC_KIND+=(tr) DOC_TEXT+=("${r//$'\n'/$'\x1f'}"); }
bm_doc_pre() { DOC_KIND+=(pre) DOC_TEXT+=("$1"); }

# The document for dialog.py: kind and text, each followed by a NUL
bm_doc_nul() {
   local i
   for i in "${!DOC_KIND[@]}"; do printf '%s\0%s\0' "${DOC_KIND[i]}" "${DOC_TEXT[i]}"; done
}

bm_doc_render_text() {
   local i kind text out="" cells cell line
   for i in "${!DOC_KIND[@]}"; do
      kind="${DOC_KIND[i]}"
      text="${DOC_TEXT[i]}"
      # Terminal output must not carry escape sequences from device data
      # (\x1f is the cell separator of tables and is handled below)
      text="${text//[$'\001'-$'\010'$'\013'-$'\036'$'\177']/?}"
      case "$kind" in
         h) out+="== $text =="$'\n' ;;
         p) out+="$text"$'\n\n' ;;
         kv) out+="${text%%$'\t'*}: ${text#*$'\t'}"$'\n' ;;
         li) out+="  - $text"$'\n' ;;
         th | tr)
            IFS=$'\t' read -r -a cells <<< "$text"
            line=""
            for cell in "${cells[@]}"; do line+="${line:+  |  }${cell/$'\x1f'/  |  }"; done
            out+="  $line"$'\n'
            ;;
         pre) out+="    $text"$'\n' ;;
      esac
   done
   REPLY="$out"
}

# ----- dialogs ---------------------------------------------------------------
# Answers never come from anywhere but a person: there is no option to answer
# for them, and a dialog that cannot be shown is never taken as a yes.

# bm_ui_gtk MODE ARG...: dialog.py, with the current document for a message or
# a question. REPLY is what it printed. Status: 0 answered, 1 closed, 25 there
# is no window here after all (from then on, the terminal is used).
# BM_DIALOG_PROGRAM replaces dialog.py in the tests.
bm_ui_gtk() {
   local mode="$1" rc
   REPLY="$(
      case "$mode" in message | question) bm_doc_nul ;; esac |
         if [ -n "${BM_DIALOG_PROGRAM:-}" ]; then "$BM_DIALOG_PROGRAM" "$@"
         else python3 -I "$BM_LIB_DIR/dialog.py" "$@"
         fi 2>/dev/null
   )"
   rc=$?
   [ "$rc" -le 1 ] && return "$rc"
   BM_UI="tty"
   REPLY=""
   return 25
}

# bm_ui_show KIND TITLE ICON: show the current document. KIND: info|warning|error
# (the terminal and the dialog say it in words; ICON is not used any more)
bm_ui_show() {
   local title="$2"
   if [ "$BM_UI" = gtk ]; then
      bm_ui_gtk message --title="$title"
      [ "$?" -ne 25 ] && return 0
   fi
   bm_doc_render_text
   printf '%s' "$REPLY"
}

# bm_ui_choice TITLE ICON PRIMARY SECONDARY CANCEL: three buttons.
# REPLY: 1 (primary), 2 (secondary), 3 (cancel or window closed)
bm_ui_choice() {
   local title="$1" b1="$3" b2="$4" b3="$5"
   if [ "$BM_UI" = gtk ]; then
      bm_ui_gtk question --title="$title" --button="3=$b3" --button="2=$b2" --button="1=$b1" \
         --default=1 --cancel=3 --suggested=1
      if [ "$?" -ne 25 ]; then
         case "$REPLY" in 1 | 2) ;; *) REPLY=3 ;; esac
         return 0
      fi
   fi
   bm_doc_render_text
   printf '%s\n' "$REPLY"
   if [ -t 0 ]; then
      printf '  1) %s\n  2) %s\n  3) %s\n> ' "$b1" "$b2" "$b3"
      read -r REPLY || REPLY=3
      case "$REPLY" in 1 | 2) ;; *) REPLY=3 ;; esac
   else
      REPLY=3
   fi
}

# bm_ui_confirm TITLE ICON YES NO: the current document as a yes/no question
bm_ui_confirm() {
   local title="$1" yes="$3" no="$4" ans
   if [ "$BM_UI" = gtk ]; then
      bm_ui_gtk question --title="$title" --button="no=$no" --button="yes=$yes" \
         --default=yes --cancel=no --suggested=yes
      [ "$?" -ne 25 ] && { [ "$REPLY" = yes ]; return; }
   fi
   bm_doc_render_text
   printf '%s' "$REPLY"
   [ -t 0 ] || return 1
   printf '%s [%s/%s] ' "$yes?" "y" "N"
   read -r ans || return 1
   [[ $ans == [yYsS]* ]]
}

# bm_ui_confirm_risky TITLE ICON YES NO: like bm_ui_confirm, but for a
# choice that can lose data: the safe answer is the default button, so an
# accidental Enter never confirms it, and the other one is marked as risky
bm_ui_confirm_risky() {
   local title="$1" yes="$3" no="$4"
   if [ "$BM_UI" = gtk ]; then
      bm_ui_gtk question --title="$title" --button="no=$no" --button="yes=$yes" \
         --default=no --cancel=no --destructive=yes
      [ "$?" -ne 25 ] && { [ "$REPLY" = yes ]; return; }
   fi
   bm_ui_confirm "$@"
}

# bm_ui_menu TITLE TEXT KEY LABEL [KEY LABEL]...: REPLY is the key or ""
bm_ui_menu() {
   local title="$1" text="$2" out i=1 keys=() items=()
   shift 2
   if [ "$BM_UI" = gtk ]; then
      for ((i = 1; i < $#; i += 2)); do items+=("--item=${!i}=${*:i+1:1}"); done
      i=1
      bm_ui_gtk menu --title="$title" --text="$text" "${items[@]}"
      [ "$?" -ne 25 ] && return 0
   fi
   printf '%s\n' "$text"
   while [ "$#" -ge 2 ]; do
      keys+=("$1"); printf '  %d) %s\n' "$i" "$2"; shift 2; i=$((i + 1))
   done
   REPLY=""
   if [ -t 0 ]; then
      printf '> '
      read -r out || out=""
      [[ $out =~ ^[0-9]+$ ]] && [ "$out" -ge 1 ] && [ "$out" -le "${#keys[@]}" ] && REPLY="${keys[out-1]}"
   fi
}

# bm_ui_input TITLE TEXT: a line typed by the user (REPLY). Fails on Cancel,
# and in a terminal without input. TEXT is plain text.
bm_ui_input() {
   local title="$1" text="$2" out
   if [ "$BM_UI" = gtk ]; then
      bm_ui_gtk input --title="$title" --text="$text"
      case "$?" in 0) return 0 ;; 1) return 1 ;; esac
   fi
   [ -t 0 ] || return 1
   printf '%s ' "$text"
   read -r out || return 1
   REPLY="$out"
}

# bm_ui_text TITLE FILE: a scrollable technical text
bm_ui_text() {
   if [ "$BM_UI" = gtk ]; then
      bm_ui_gtk text --title="$1" --file="$2"
      [ "$?" -ne 25 ] && return 0
   fi
   cat -- "$2"
}

# ----- notifications -----------------------------------------------------------
# One path only, so a message is never shown twice: notify-send (libnotify)
# when there is a session bus; otherwise, or when it fails, a warning in a
# dialog and anything else on stderr. Durations are set here and nowhere else. Plasma honours them, and
# without one it keeps notifications that have buttons open indefinitely.
BM_POPUP_SECONDS=5      # information: disappears and is not kept in the history
BM_WARNING_SECONDS=15   # problems, possibly with buttons: time to click, kept in the history

# bm_notify info|warning ICON TITLE BODY [KEY=LABEL]...: with actions it blocks
# until the user reacts or the notification expires, and prints the chosen
# key; callers run it in the background. Decisions never go through here:
# they use dialogs that do not expire.
bm_notify() {
   local kind="$1" icon="$2" title="$3" body="$4" secs="$BM_POPUP_SECONDS" a opts=()
   shift 4
   if [ "$kind" = warning ]; then
      secs="$BM_WARNING_SECONDS"
   else
      opts+=(--transient)
   fi
   for a in "$@"; do opts+=(--action "$a"); done
   bm_html "$body"
   if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v notify-send >/dev/null \
      && notify-send --app-name "$BM_APP_NAME" --icon "$icon" --expire-time "$((secs * 1000))" \
         --hint string:desktop-entry:big-mount "${opts[@]}" -- "$title" "$REPLY" 2>/dev/null; then
      return 0
   fi
   # A warning stays in sight without a notification server (the notifier
   # started with the session has no terminal): a window, with the actions as
   # buttons; the key chosen is printed, as notify-send does. Its document is
   # its own, the caller's is left as it was.
   if [ "$kind" = warning ] && [ "${BM_UI:-}" = gtk ]; then
      local DOC_KIND=() DOC_TEXT=() buttons=("--button=close="$"Close")
      for a in "$@"; do buttons+=("--button=$a"); done
      bm_doc_p "$body"
      bm_ui_gtk question --title="$title" "${buttons[@]}" --default=close --cancel=close
      if [ "$?" -ne 25 ]; then
         [ -n "$REPLY" ] && [ "$REPLY" != close ] && printf '%s\n' "$REPLY"
         return 0
      fi
   fi
   # No notification server, or it refused: the message is not lost. One line,
   # and device data brings no escape sequence to the terminal
   title="${title//$'\n'/; }" body="${body//$'\n'/; }"
   printf '%s: %s\n' "${title//[[:cntrl:]]/?}" "${body//[[:cntrl:]]/?}" >&2
}
