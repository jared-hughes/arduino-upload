{CompositeDisposable} = require 'atom'
{spawn} = require 'child_process'
String::strip = -> if String::trim? then @trim() else @replace /^\s+|\s+$/g, ""

fs = require 'fs'
path = require 'path'
OutputView = require './output-view'
SerialView = require './serial-view'
tmp = require 'tmp'

try
	serialport = require 'serialport'
catch e
	serialport = null
try
	usbDetect = require 'usb-detection'
catch e
	usbDetect = null

output = null
serial = null
serialeditor = null

seperator = '/'
if /^win/.test process.platform
	seperator = '\\'

removeDir = (dir) ->
	if fs.existsSync dir
		for file in fs.readdirSync dir
			path = dir + '/' + file
			if fs.lstatSync(path).isDirectory()
				removeDir path
			else
				fs.unlinkSync path
			
		fs.rmdirSync dir
module.exports = ArduinoUpload =
	config:
		arduinoExecutablePath:
			title: 'Arduino Executable Path'
			description: 'The location of the arduino IDE executable, your PATH is being searched, too'
			type: 'string'
			default: 'arduino'
		baudRate:
			title: 'BAUD Rate'
			description: 'Sets the BAUD rate for the serial monitor, if you change it you need to close and open it manually'
			type: 'number'
			default: '9600'
		board:
			title: 'Arduino board'
			description: 'If kept blank, it will take the settings from the arduino IDE. The board uses the pattern as described <a href="https://github.com/arduino/Arduino/blob/ide-1.5.x/build/shared/manpage.adoc#options">here</a>'
			type: 'string'
			default: ''
		lineEnding:
			title: 'Default line ending in serial monitor'
			description: '0 - No line ending<br>1 - Newline<br>2 - Carriage return<br>3 - Both NL &amp; CR'
			type: 'integer'
			default: 1
			minimum: 0
			maximum: 3
	vendorsArduino: {
		0x2341: true # Arduino
		0x2a03: true # Arduino M0 Pro (perhaps other devices?)
		0x03eb: true # Atmel
		# knockoff producers
		0x0403: [ 0x6001 ] # FTDI 
		0x1a86: [ 0x7523 ] # QuinHeng
		0x0403: [ 0x6001 ] # Future Technology Devices International, Ltd
	}
	vendorsProgrammer: {
		0x03eb: [ 0x2141 ] # Atmel ICE debugger
	}
	buildFolders: []
	activate: (state) ->
		# Setup to use the new composite disposables API for registering commands
		@subscriptions = new CompositeDisposable
		@subscriptions.add atom.commands.add "atom-workspace",
			'arduino-upload:verify': => @build(false)
		@subscriptions.add atom.commands.add "atom-workspace",
			'arduino-upload:build': => @build(true)
		@subscriptions.add atom.commands.add "atom-workspace",
			'arduino-upload:upload': => @upload()
		@subscriptions.add atom.commands.add "atom-workspace",
			'arduino-upload:serial-monitor': => @openserial()
		
		output = new OutputView
		atom.workspace.addBottomPanel(item:output)
		output.hide()

	deactivate: ->
		for own s, f of @buildFolders
			removeDir f
		@subscriptions.dispose()
		output?.remove()
		@closeserial()
	
	additionalArduinoOptions: (path, port = false) ->
		options = ['-v']
		if atom.config.get('arduino-upload.board') != ''
			options = options.concat ['--board', atom.config.get('arduino-upload.board')]
		if typeof port != 'boolean'
			if port == 'PROGRAMMER'
				options.push '--useprogrammer'
			else if port != 'ARDUINO'
				options = options.concat ['--port', port]
		if not @buildFolders[path]
			@buildFolders[path] = tmp.dirSync().name
		options = options.concat ['--pref', 'build.path='+@buildFolders[path]]
		return options
	_build: (options, callback, onerror, port = false) ->
		editor = atom.workspace.getActivePaneItem()
		file = editor?.buffer?.file?.getPath()?.split seperator
		file?.pop()
		name = file?.pop()
		file?.push name
		workpath = file?.join seperator
		name += '.ino'
		file?.push name
		file = file?.join seperator
		dispError = false
		output.reset()
		if not fs.existsSync file
			atom.notifications.addError "File isn't part of an Arduino sketch!"
			callback false
			return
		atom.notifications.addInfo 'Start building...'
		
		options = [file].concat(options).concat @additionalArduinoOptions file, port
		stdoutput = spawn atom.config.get('arduino-upload.arduinoExecutablePath'), options
		
		error = false
		
		stdoutput.on 'error', (err) =>
			atom.notifications.addError "Can't find the arduino IDE, please install it and set <i>Arduino Executable Path</i> correctly in the settings! (" + err + ")"
			callback false
			error = true
		stdoutput.stdout.on 'data', (data) =>
			if data.toString().strip().indexOf('Sketch') == 0 || data.toString().strip().indexOf('Global') == 0
				atom.notifications.addInfo data.toString()
		
		stdoutput.stderr.on 'data', (data) =>
			overrideError = false
			if onerror
				overrideError = onerror(data)
			if data.toString().strip() == "exit status 1"
				dispError = false
			if dispError && !overrideError
				console.log data.toString()
				output.addLine data.toString(), workpath
			if data.toString().strip() == "Verifying..." || data.toString().strip() == "Verifying and uploading..."
				dispError = true
		
		stdoutput.on 'close', (code) =>
			if error
				return
			info = {
				'buildFolder': @buildFolders[file]
				'name': name
				'workpath': workpath
			}
			callback code, info
			output.finish()
	build: (keep) ->
		@_build ['--verify'], (code, info) =>
			if code != false
				if code != 0
					atom.notifications.addError 'Build failed'
				else if keep
					for ending in ['.eep','.elf','.hex']
						fs.createReadStream(info.buildFolder + info.name + ending).pipe(fs.createWriteStream(info.workpath + seperator + info.name + ending))
		
	upload: ->
		@getPort (port) =>
			if port == ''
				atom.notifications.addError 'No arduino connected'
				return
			callback = (code, info) =>
				if code != false
					if code == 0
						atom.notifications.addInfo 'Successfully uploaded sketch'
					else
						if uploading
							atom.notifications.addError "Couldn't upload to board, is it connected?"
						else
							atom.notifications.addError 'Build failed'
				if serial != null
					@_openserialport port, false
			uploading = false
			onerror = (data) =>
				s = data.toString().strip()
				if (s.indexOf("avrdude:") == 0 || s.indexOf("Uploading...") == 0) && !uploading
					uploading = true
					atom.notifications.addInfo 'Uploading sketch...'
				return uploading
			if serial == null
				# no serial connection open to halt
				@_build ['--upload'], callback, onerror, port
				return
			@serialNormalClose = false
			serial.close (err) =>
				@_build ['--upload'], callback, onerror, port
	isArduino: (vid, pid, vendors = false) ->
		vid = parseInt vid
		pid = parseInt pid
		if !vendors
			vendors = @vendorsArduino
		for own v, p of vendors
			if vid == parseInt v
				if p && typeof p == 'boolean' 
					return true
				if -1 != p.indexOf pid
					return true
		return false
	_getPort: (callback) ->
		serialport.list (err, ports) =>
			p = ''
			for port in ports
				if @isArduino(port.vendorId, port.productId)
					p = port.comName
					break
			callback p
	getPort: (callback) ->
		if serialport == null and usbDetect == null
			callback 'ARDUINO'
			return
		if usbDetect == null
			@_getPort callback
			return
		usbDetect.find (err, ports) =>
			for port in ports
				if @isArduino(port.vendorId, port.productId, @vendorsProgrammer)
					callback 'PROGRAMMER'
					return
			if serialport == null
				callback 'ARDUINO'
				return
			@_getPort callback
	serialNormalClose: true
	_openserialport: (port, start = true)->
		try
			serial = new serialport.SerialPort port, {
					baudRate: atom.config.get('arduino-upload.baudRate')
					parser: serialport.parsers.raw
				}
			@serialNormalClose = true
			serial.on 'open', (data) =>
				if start
					atom.notifications.addInfo 'new serial connection'
			serial.on 'data', (data) =>
				serialeditor?.insertText data
			serial.on 'close', (data) =>
				if @serialNormalClose
					@closeserial()
					atom.notifications.addInfo 'Serial connection closed'
			serial.on 'error', (data) =>
				console.log data
				@closeserial()
				atom.notifications.addInfo 'error in serial connection'
		catch e
			@closeserial()
			atom.notifications.addError e
	openserialport: ->
		if serial!=null
			atom.notifications.addInfo 'wut, serial open?'
			return
		p = ''
		@getPort (port) =>
			if port == 'PROGRAMMER'
				atom.notifications.addError 'Can\'t use a programmer as serial monitor!'
				@closeserial()
				return
			if port == '' or port == 'ARDUINO'
				atom.notifications.addError 'No Arduino found!'
				@closeserial()
				return
			
			@_openserialport(port)
	openserial: ->
		if serialport == null
			atom.notifications.addInfo 'Serialport dependency not present, try installing it! (And, if you figure out how, please report me how <a href="https://github.com/Sorunome/arduino-upload/issues">here</a> as I don\'t know how to do it..... Really, <b>please</b> help me! D: )'
			return
		if serial!=null
			return
		
		serialeditor = new SerialView
		serialeditor.open =>
			serialeditor.onDidDestroy =>
				@closeserial()
			serialeditor.onSend (s) =>
				serial?.write s
			@openserialport()
	closeserial: ->
		serial?.close (err) ->
			return
		serial = null
		
		serialeditor?.destroy()
		serialeditor = null
