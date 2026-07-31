module github.com/docker-library/meta-scripts

go 1.26

require (
	cuelabs.dev/go/oci/ociregistry v0.0.0-20240214163758-5ebe80b0a9a6
	github.com/docker-library/bashbrew v0.1.11
	github.com/go-git/go-git/v5 v5.5.1
	github.com/go-json-experiment/json v0.0.0-20260623181947-01eb4420fa68
	github.com/opencontainers/go-digest v1.0.0
	github.com/opencontainers/image-spec v1.1.0
	golang.org/x/time v0.5.0
)

require (
	github.com/Microsoft/go-winio v0.6.0 // indirect
	github.com/ProtonMail/go-crypto v0.0.0-20221026131551-cf6655e29de4 // indirect
	github.com/acomagu/bufpipe v1.0.3 // indirect
	github.com/cloudflare/circl v1.3.1 // indirect
	github.com/containerd/containerd v1.6.19 // indirect
	github.com/emirpasic/gods v1.18.1 // indirect
	github.com/go-git/gcfg v1.5.0 // indirect
	github.com/go-git/go-billy/v5 v5.3.1 // indirect
	github.com/golang/protobuf v1.5.2 // indirect
	github.com/imdario/mergo v0.3.13 // indirect
	github.com/jbenet/go-context v0.0.0-20150711004518-d14ea06fba99 // indirect
	github.com/kevinburke/ssh_config v1.2.0 // indirect
	github.com/pjbgf/sha1cd v0.2.3 // indirect
	github.com/sergi/go-diff v1.2.0 // indirect
	github.com/sirupsen/logrus v1.9.0 // indirect
	github.com/skeema/knownhosts v1.1.0 // indirect
	github.com/xanzy/ssh-agent v0.3.3 // indirect
	golang.org/x/crypto v0.14.0 // indirect
	golang.org/x/mod v0.13.0 // indirect
	golang.org/x/net v0.16.0 // indirect
	golang.org/x/sys v0.13.0 // indirect
	golang.org/x/tools v0.14.0 // indirect
	google.golang.org/genproto v0.0.0-20221207170731-23e4bf6bdc37 // indirect
	google.golang.org/grpc v1.51.0 // indirect
	google.golang.org/protobuf v1.28.1 // indirect
	gopkg.in/warnings.v0 v0.1.2 // indirect
)

// https://github.com/cue-labs/oci/pull/29
replace cuelabs.dev/go/oci/ociregistry => github.com/tianon/cuelabs-oci/ociregistry v0.0.0-20240329232705-b652d611e4b3
