# web-test os/win-file-dialog v1.0 — Fill the native Windows file/folder dialog opened by the 1C file system extension.
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
#
# Waits for a visible #32770 window of a 1CFileExtension* process, puts -Path into its "File name"
# (or, in the folder dialog, "Folder") field and presses Open / Select Folder. Prints one ASCII line: FILLED | TIMEOUT | FAILED <reason>.
# UI Automation does not see this window from the desktop root, and exposes its classic controls
# without patterns — so plain Win32: EnumWindows, WM_SETTEXT, BM_CLICK.
param(
  [Parameter(Mandatory)][string]$Path,
  [int]$TimeoutMs = 10000
)
# The FAILED reason may carry a localized exception message: keep it readable for Node
[Console]::OutputEncoding = [Text.Encoding]::UTF8
try {
Add-Type @'
using System; using System.Text; using System.Diagnostics; using System.Runtime.InteropServices;
public static class WebTestFileDialog {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr GetDlgItem(IntPtr h, int id);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr p, IntPtr after, string cls, string title);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, string l);
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  const uint WM_SETTEXT = 0x000C, BM_CLICK = 0x00F5;
  // "File name" combo of the file dialog; "Folder" edit of the folder dialog (ВыборКаталога)
  const int IDOK = 1, IDCANCEL = 2, FILE_NAME_COMBO = 1148, FOLDER_EDIT = 1152;

  static bool IsExtensionProcess(uint pid) {
    try { return Process.GetProcessById((int)pid).ProcessName.StartsWith("1CFileExtension"); }
    catch { return false; }
  }
  public static IntPtr Find() {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      var c = new StringBuilder(64); GetClassName(h, c, 64);
      if (c.ToString() != "#32770" || !IsWindowVisible(h)) return true;
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (!IsExtensionProcess(pid)) return true;
      // A file/folder dialog has its name field; message boxes of the extension are #32770 too
      if (GetDlgItem(h, FILE_NAME_COMBO) == IntPtr.Zero && GetDlgItem(h, FOLDER_EDIT) == IntPtr.Zero) return true;
      found = h; return false;
    }, IntPtr.Zero);
    return found;
  }
  public static string Fill(IntPtr dlg, string path) {
    IntPtr combo = GetDlgItem(dlg, FILE_NAME_COMBO);
    IntPtr inner = combo == IntPtr.Zero ? IntPtr.Zero : FindWindowEx(combo, IntPtr.Zero, "ComboBox", null);
    IntPtr edit = combo == IntPtr.Zero ? GetDlgItem(dlg, FOLDER_EDIT)
      : FindWindowEx(inner != IntPtr.Zero ? inner : combo, IntPtr.Zero, "Edit", null);
    IntPtr ok = GetDlgItem(dlg, IDOK);
    if (edit == IntPtr.Zero || ok == IntPtr.Zero) {
      // Unknown dialog layout: do not leave it hanging
      IntPtr cancel = GetDlgItem(dlg, IDCANCEL);
      if (cancel != IntPtr.Zero) SendMessage(cancel, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
      return "FAILED " + (edit == IntPtr.Zero ? "no file or folder name field" : "no Open button");
    }
    SendMessage(edit, WM_SETTEXT, IntPtr.Zero, path);
    SendMessage(ok, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
    // The dialog stays open when it rejects the path (its own message box) — cancel it then
    for (int i = 0; i < 20 && IsWindowVisible(dlg); i++) System.Threading.Thread.Sleep(100);
    if (IsWindowVisible(dlg)) {
      IntPtr cancel = GetDlgItem(dlg, IDCANCEL);
      if (cancel != IntPtr.Zero) SendMessage(cancel, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
      return "FAILED dialog did not accept the path";
    }
    return "FILLED";
  }
}
'@
$deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
while ([DateTime]::UtcNow -lt $deadline) {
  $dlg = [WebTestFileDialog]::Find()
  if ($dlg -ne [IntPtr]::Zero) { [Console]::Out.WriteLine([WebTestFileDialog]::Fill($dlg, $Path)); exit 0 }
  Start-Sleep -Milliseconds 200
}
[Console]::Out.WriteLine('TIMEOUT')
} catch {
  # Add-Type blocked or failed (constrained language, AV): report it instead of a silent TIMEOUT
  [Console]::Out.WriteLine("FAILED $($_.Exception.Message -replace '\s+', ' ')")
}
