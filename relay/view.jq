# JSONL transcript -> compact one-line-per-event text.
# Tool calls and their results are kept (truncated), because "what was actually
# run and what came back" is the part a summary must never lose.
select(.message.content != null)
| (.message.role // "?") as $r
| (if (.message.content | type) == "string"
   then [{type: "text", text: .message.content}]
   else .message.content end)
| .[]
| if .type == "text" then
    (if $r == "user" then "U: " else "A: " end) + (.text | gsub("\\s+"; " ") | .[0:700])
  elif .type == "tool_use" then
    "TOOL " + (.name // "?") + ": " + ((.input // {}) | tostring | .[0:320])
  elif .type == "tool_result" then
    "RES: " + ((.content // "") | tostring | gsub("\\s+"; " ") | .[0:320])
  else empty end
