package hotload_gen

import "core:sys/windows"
import "core:os"

console_can_be_colored :: proc() -> bool {
	console := cast(windows.HANDLE)os.stdout;
	if console != nil {
		mode: windows.DWORD;
		windows.GetConsoleMode(console, &mode);
		if (mode & windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0 {
			return true;
		}
	}
	return false;
}