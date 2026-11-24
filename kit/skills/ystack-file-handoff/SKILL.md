---
name: ystack-file-handoff
description: "Transfer long text between agents through an authorized shared file when chat delivery truncates content, and verify completeness before use."
---

# File Handoff

Use an existing authorized shared location. This workflow grants no new access or messaging permission. If the recipient cannot read that location, stop and report the missing access.

1. Write the full text to a unique task file with one writer. On Unix, restrict its permissions to mode 600. Exclude secrets and content the recipient may not access. Agents sharing the same OS account are not isolated by mode 600.
2. End the file with an agreed marker, such as `【完】`. Close the file, measure its byte size, and keep it unchanged until receipt.
3. Send only the path and byte size through the authorized channel. The recipient reads the file and checks both size and end marker before using it. A mismatch requires a fresh complete transfer; never reconstruct missing text by guessing.
4. Return the requested result from the complete text. If relaying verbatim, preserve every section and link. Delete the temporary file after confirmed receipt when retention rules allow, or keep it in protected storage.

## Limits

The chat truncation threshold is unknown. Size and an end marker detect incomplete delivery; they do not authenticate a sender or prove content integrity.
