BINARY = audio-capture
SOURCES = $(wildcard Sources/*.swift)
INSTALL_DIR = /usr/local/bin

$(BINARY): $(SOURCES)
	swiftc -O -o $@ $(SOURCES) -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia

.PHONY: install clean

install: $(BINARY)
	install -d $(INSTALL_DIR)
	install -m 755 $(BINARY) $(INSTALL_DIR)/$(BINARY)

clean:
	rm -f $(BINARY)
