import topbar from "../../vendor/topbar";

export default function imageHandler({ dropTarget = window, textareaId } = {}) {
  const csrfToken = document
    .querySelector("meta[name='csrf-token']")
    .getAttribute("content");

  const overlay = document.createElement("div");
  Object.assign(overlay.style, {
    position: "fixed",
    inset: "0",
    background: "rgba(0, 0, 0, 0.5)",
    display: "none",
    pointerEvents: "none",
    zIndex: "9999",
  });
  document.body.appendChild(overlay);

  let dragDepth = 0;

  function showOverlay() {
    overlay.style.display = "block";
  }

  function hideOverlay() {
    dragDepth = 0;
    overlay.style.display = "none";
  }

  function insertAtCursor(textarea, text) {
    textarea.focus();
    // execCommand preserves undo history and fires `input` so LiveView sees it
    const inserted = document.execCommand("insertText", false, text);
    if (inserted) return;

    // Fallback for browsers where execCommand("insertText") is unsupported
    const start = textarea.selectionStart ?? textarea.value.length;
    const end = textarea.selectionEnd ?? textarea.value.length;
    textarea.value =
      textarea.value.slice(0, start) + text + textarea.value.slice(end);
    const caret = start + text.length;
    textarea.setSelectionRange(caret, caret);
    textarea.dispatchEvent(new Event("input", { bubbles: true }));
  }

  function queueUpload(textarea, file) {

    insertAtCursor(textarea, `![Uploading ${file.name}…]()`);
    window.dispatchEvent(
      new CustomEvent("sign-image-url", {
        detail: { name: file.name, type: file.type, size: file.size, file },
      }),
    );
  }

  function handleDrop(event) {
    event.preventDefault();
    hideOverlay();

    const textarea = textareaId && document.getElementById(textareaId);
    if (!textarea) {
      console.warn(`imageHandler: textarea "${textareaId}" not found`);
      return;
    }

    const files = Array.from(event.dataTransfer.files);
    if (files.length === 0) return;

    topbar.show(300);
    files.forEach((file) => queueUpload(textarea, file));
  }

  function handlePaste(event) {
    const textarea = textareaId && document.getElementById(textareaId);
    if (!textarea || document.activeElement !== textarea) return;

    const images = Array.from(event.clipboardData?.files || []).filter((f) =>
      f.type.startsWith("image/"),
    );
    if (images.length === 0) return;

    event.preventDefault();
    topbar.show(300);

    images.forEach((file) => {
      // Pasted screenshots usually arrive as "image.png" — rename so the
      // placeholder lookup is unique per paste, and so the alt text is useful.
      const ext = (file.type.split("/")[1] || "png").replace("jpeg", "jpg");
      const name = `pasted-${Date.now()}.${ext}`;
      const renamed = new File([file], name, { type: file.type });
      queueUpload(textarea, renamed);
    });
  }

  dropTarget.addEventListener("dragenter", () => {
    dragDepth++;
    showOverlay();
  });
  dropTarget.addEventListener("dragleave", () => {
    dragDepth--;
    if (dragDepth <= 0) hideOverlay();
  });
  dropTarget.addEventListener("dragover", (e) => e.preventDefault());
  dropTarget.addEventListener("drop", handleDrop);
  document.addEventListener("paste", handlePaste);
}
