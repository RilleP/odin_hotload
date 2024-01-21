**Getting started**
- build generator program:
  $odin build generator

- using in your program
  $generator.exe 'path_to_your_package' -loader

  // call this at start of your program
  hotloader.start(hotload_procs, hotload_files, "generator.exe")

  // call this in your main loop
  reload_result := hotloader.reload_if_changed(nil, nil)
	
- making a proc hotloadable
	// Add @hotload attribute and make it mutable by changing :: to :=
	foo :: proc() 

	@hotload foo := proc()

**Known issues:**

- Changing a struct declaration that is used by an hotloaded function while the program is running will break the program (some times).

- Calling functions of imported libraries that read/write any global state of that library does not work, since the hotloaded dll has its own version of that global state. So wrappers has to be made for those functions.

- Changing signatures of hotloaded functions that are called from not-hotloaded functions does not work.