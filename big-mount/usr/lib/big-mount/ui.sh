# shellcheck shell=bash
#
# big-mount user interface: the same content rendered for KDialog (Plasma),
# Zenity (GNOME edition) or a terminal, plus desktop notifications.
#
# Content is built as a small document (bm_doc_*), so that untrusted text
# (volume labels, file and process names) is escaped in one place for each
# backend and no backend-specific markup ends up in translatable strings.
# Nothing here ever runs as root: the GUI belongs to the user session.

bm_ui_init() {
   BM_UI="${BM_UI:-}"
   if [ -z "$BM_UI" ]; then
      BM_UI="tty"
      if [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
         if command -v kdialog >/dev/null; then
            BM_UI=kdialog
         elif command -v zenity >/dev/null; then
            BM_UI=zenity
         fi
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

# Pango and Qt rich text need the same escaping
bm_doc_render_markup() {
   local mode="$1" i kind text out="" in_list=0 in_table=0 cell cells k v
   for i in "${!DOC_KIND[@]}"; do
      kind="${DOC_KIND[i]}"
      text="${DOC_TEXT[i]}"
      if [ "$mode" = html ]; then
         if [ "$in_list" -eq 1 ] && [ "$kind" != li ]; then out+="</ul>"; in_list=0; fi
         if [ "$in_table" -eq 1 ] && [ "$kind" != tr ] && [ "$kind" != th ]; then out+="</table>"; in_table=0; fi
      fi
      case "$kind" in
         h)
            bm_html "$text"
            if [ "$mode" = html ]; then out+="<h3>$REPLY</h3>"; else out+="<big><b>$REPLY</b></big>"$'\n\n'; fi
            ;;
         p)
            bm_html "$text"; REPLY="${REPLY//$'\n'/<br>}"
            if [ "$mode" = html ]; then out+="<p>$REPLY</p>"; else out+="${REPLY//<br>/$'\n'}"$'\n\n'; fi
            ;;
         kv)
            bm_html "${text%%$'\t'*}"; k="$REPLY"
            bm_html "${text#*$'\t'}"; v="$REPLY"
            if [ "$mode" = html ]; then out+="<b>$k:</b> $v<br>"; else out+="<b>$k:</b> $v"$'\n'; fi
            ;;
         li)
            bm_html "$text"
            if [ "$mode" = html ]; then
               [ "$in_list" -eq 0 ] && { out+="<ul>"; in_list=1; }
               out+="<li>$REPLY</li>"
            else
               out+="  • $REPLY"$'\n'
            fi
            ;;
         th | tr)
            IFS=$'\t' read -r -a cells <<< "$text"
            if [ "$mode" = html ]; then
               [ "$in_table" -eq 0 ] && { out+="<table cellspacing=\"0\" cellpadding=\"4\">"; in_table=1; }
               out+="<tr>"
               # Text columns may wrap; short middle columns (PID, user) stay
               # on one line. A newline in a cell starts a smaller second line.
               local col=0 last=$((${#cells[@]} - 1)) wrap
               for cell in "${cells[@]}"; do
                  bm_html "$cell"
                  REPLY="${REPLY/$'\x1f'/<br><small>}"
                  [[ $REPLY == *"<small>"* ]] && REPLY+="</small>"
                  wrap=' style="white-space:nowrap"'
                  { [ "$col" -eq 0 ] || [ "$col" -eq "$last" ]; } && wrap=""
                  col=$((col + 1))
                  if [ "$kind" = th ]; then
                     out+="<th align=\"left\"$wrap>$REPLY</th>"
                  else
                     out+="<td valign=\"top\"$wrap>$REPLY</td>"
                  fi
               done
               out+="</tr>"
            else
               local line=""
               for cell in "${cells[@]}"; do bm_html "${cell/$'\x1f'/ — }"; line+="${line:+  ·  }$REPLY"; done
               if [ "$kind" = th ]; then out+="<b>$line</b>"$'\n'; else out+="$line"$'\n'; fi
            fi
            ;;
         pre)
            bm_html "$text"
            if [ "$mode" = html ]; then out+="<pre>$REPLY</pre>"; else out+="<tt>$REPLY</tt>"$'\n'; fi
            ;;
      esac
   done
   if [ "$mode" = html ]; then
      [ "$in_list" -eq 1 ] && out+="</ul>"
      [ "$in_table" -eq 1 ] && out+="</table>"
      REPLY="<html>$out</html>"
   else
      REPLY="${out%$'\n'}"
   fi
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

# bm_ui_show KIND TITLE ICON: show the current document. KIND: info|warning|error
bm_ui_show() {
   local kind="$1" title="$2" icon="${3:-}"
   case "$BM_UI" in
      kdialog)
         bm_doc_render_markup html
         local opt=--msgbox
         [ "$kind" = warning ] && opt=--sorry
         [ "$kind" = error ] && opt=--error
         kdialog --title "$title" ${icon:+--icon "$icon"} "$opt" "$REPLY" >/dev/null 2>&1
         ;;
      zenity)
         bm_doc_render_markup pango
         local opt=--info
         [ "$kind" = warning ] && opt=--warning
         [ "$kind" = error ] && opt=--error
         zenity "$opt" --title "$title" ${icon:+--icon "$icon"} --width 520 --text "$REPLY" >/dev/null 2>&1
         ;;
      *)
         bm_doc_render_text
         printf '%s' "$REPLY"
         ;;
   esac
}

# bm_ui_choice TITLE ICON PRIMARY SECONDARY CANCEL: three buttons.
# REPLY: 1 (primary), 2 (secondary), 3 (cancel or window closed)
bm_ui_choice() {
   local title="$1" icon="$2" b1="$3" b2="$4" b3="$5" out rc
   case "$BM_UI" in
      kdialog)
         bm_doc_render_markup html
         kdialog --title "$title" ${icon:+--icon "$icon"} --warningyesnocancel "$REPLY" \
            --yes-label "$b1" --no-label "$b2" --cancel-label "$b3" >/dev/null 2>&1
         rc=$?
         case "$rc" in 0) REPLY=1 ;; 1) REPLY=2 ;; *) REPLY=3 ;; esac
         ;;
      zenity)
         bm_doc_render_markup pango
         out="$(zenity --question --title "$title" ${icon:+--icon "$icon"} --width 560 --text "$REPLY" \
            --ok-label "$b1" --cancel-label "$b3" --extra-button "$b2" 2>/dev/null)"
         rc=$?
         if [ "$rc" -eq 0 ]; then REPLY=1; elif [ "$out" = "$b2" ]; then REPLY=2; else REPLY=3; fi
         ;;
      *)
         bm_doc_render_text
         printf '%s\n' "$REPLY"
         if [ -t 0 ]; then
            printf '  1) %s\n  2) %s\n  3) %s\n> ' "$b1" "$b2" "$b3"
            read -r REPLY || REPLY=3
            case "$REPLY" in 1 | 2) ;; *) REPLY=3 ;; esac
         else
            REPLY=3
         fi
         ;;
   esac
}

# bm_ui_confirm TITLE ICON YES NO: the current document as a yes/no question
bm_ui_confirm() {
   local title="$1" icon="$2" yes="$3" no="$4" ans
   case "$BM_UI" in
      kdialog)
         bm_doc_render_markup html
         kdialog --title "$title" ${icon:+--icon "$icon"} --warningyesno "$REPLY" \
            --yes-label "$yes" --no-label "$no" >/dev/null 2>&1
         ;;
      zenity)
         bm_doc_render_markup pango
         zenity --question --title "$title" ${icon:+--icon "$icon"} --width 520 --text "$REPLY" \
            --ok-label "$yes" --cancel-label "$no" >/dev/null 2>&1
         ;;
      *)
         bm_doc_render_text
         printf '%s' "$REPLY"
         [ -t 0 ] || return 1
         printf '%s [%s/%s] ' "$yes?" "y" "N"
         read -r ans || return 1
         [[ $ans == [yYsS]* ]]
         ;;
   esac
}

# bm_ui_menu TITLE TEXT KEY LABEL [KEY LABEL]...: REPLY is the key or ""
bm_ui_menu() {
   local title="$1" text="$2" out i=1 keys=()
   shift 2
   case "$BM_UI" in
      kdialog)
         out="$(kdialog --title "$title" --menu "$text" "$@" 2>/dev/null)" || out=""
         REPLY="$out"
         ;;
      zenity)
         local rows=()
         while [ "$#" -ge 2 ]; do rows+=("$1" "$2"); shift 2; done
         out="$(zenity --list --title "$title" --text "$text" --column key --column "" \
            --hide-column 1 --print-column 1 --hide-header --width 520 --height 360 "${rows[@]}" 2>/dev/null)" || out=""
         REPLY="$out"
         ;;
      *)
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
         ;;
   esac
}

# bm_ui_text TITLE FILE: a scrollable technical text
bm_ui_text() {
   case "$BM_UI" in
      kdialog) kdialog --title "$1" --textbox "$2" 760 480 >/dev/null 2>&1 ;;
      zenity) zenity --text-info --title "$1" --filename "$2" --width 760 --height 480 >/dev/null 2>&1 ;;
      *) cat -- "$2" ;;
   esac
}

# bm_notify ICON TITLE BODY [KEY=LABEL]...: desktop notification. With
# actions it blocks until the user reacts and prints the chosen key; callers
# run it in the background.
bm_notify() {
   local icon="$1" title="$2" body="$3" acts=() a
   shift 3
   for a in "$@"; do acts+=(--action "$a"); done
   if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v notify-send >/dev/null; then
      bm_html "$body"
      notify-send --app-name "$BM_APP_NAME" --icon "$icon" \
         --hint string:desktop-entry:big-mount "${acts[@]}" -- "$title" "$REPLY" 2>/dev/null
   else
      printf '%s: %s\n' "$title" "$body" >&2
   fi
}
