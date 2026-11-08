NAME := Ksign
# File name of the finished package in packages/ (the Xcode target is still called Ksign).
IPA_NAME := Ofuq
PLATFORM := iphoneos
SCHEMES := Ksign
TMP := $(TMPDIR)/$(NAME)
STAGE := $(TMP)/stage
APP := $(TMP)/Build/Products/Release-$(PLATFORM)

.PHONY: all clean $(SCHEMES)

all: $(SCHEMES)

clean:
	rm -rf "$(TMP)"
	rm -rf packages
	rm -rf Payload

deps:
	rm -rf deps || true
	mkdir -p deps
	# The old backloop.dev-*.pem/.crt URLs return "404 Not Found" HTML, which used to be bundled as the
	# certificate. Read the same pack.json the app uses, and bundle nothing if it cannot be fetched/parsed
	# (the app then downloads the certificates at launch, or falls back to Semi Local).
	curl -fsSL -o deps/pack.json https://backloop.dev/pack.json && \
	python3 -c 'import json; p = json.load(open("deps/pack.json")); \
	open("deps/server.crt", "w").write(p["cert"]); \
	open("deps/server.pem", "w").write(p["key1"] + p["key2"]); \
	open("deps/commonName.txt", "w").write(p["info"]["domains"]["commonName"])' \
	|| (rm -f deps/server.crt deps/server.pem deps/commonName.txt; echo "warning: could not fetch backloop.dev SSL pack, building without bundled certificates")
	rm -f deps/pack.json

$(SCHEMES): deps
	xcodebuild \
	    -project Ksign.xcodeproj \
	    -scheme "$@" \
	    -configuration Release \
	    -arch arm64 \
	    -sdk $(PLATFORM) \
	    -derivedDataPath $(TMP) \
	    -skipPackagePluginValidation \
	    CODE_SIGNING_ALLOWED=NO \
	    ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO

	rm -rf Payload
	rm -rf "$(STAGE)/"
	mkdir -p "$(STAGE)/Payload"

	mv "$(APP)/$@.app" "$(STAGE)/Payload/$@.app"

	chmod -R 0755 "$(STAGE)/Payload/$@.app"
	codesign --force --sign - --timestamp=none "$(STAGE)/Payload/$@.app"

	cp deps/* "$(STAGE)/Payload/$@.app/" || true

	rm -rf "$(STAGE)/Payload/$@.app/_CodeSignature"
	ln -sf "$(STAGE)/Payload" Payload
	
	mkdir -p packages
	zip -r9 "packages/$(IPA_NAME).ipa" Payload