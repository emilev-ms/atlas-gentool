# The docker image to generate Golang code from Protol Buffer.
FROM golang:1.17.0-alpine3.14 as builder
LABEL intermediate=true
MAINTAINER DL NGP-App-Infra-API <ngp-app-infra-api@infoblox.com>

# Set up mandatory Go environmental variables.
ENV CGO_ENABLED=0

RUN apk update \
    && apk add --no-cache --purge git dep

# Use go modules to download application code and dependencies
WORKDIR ${GOPATH}/src/github.com/infobloxopen/atlas-gentool
COPY go.mod .
COPY go.sum .
COPY tools.go .
RUN go mod vendor

# Copy to /go/src so the protos will be available
RUN cp -r vendor/* ${GOPATH}/src/

# Build protoc tools
RUN go install github.com/golang/protobuf/protoc-gen-go@v1.5.3
RUN go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.2.0
RUN go install github.com/chrusty/protoc-gen-jsonschema/cmd/protoc-gen-jsonschema
RUN go install github.com/envoyproxy/protoc-gen-validate@v0.9.0
RUN go install github.com/mwitkow/go-proto-validators/protoc-gen-govalidators@v0.3.2
RUN go install github.com/pseudomuto/protoc-gen-doc/cmd/protoc-gen-doc@v1.5.0
RUN go install github.com/infobloxopen/protoc-gen-preprocess@v1.0.1
RUN cd ${GOPATH}/src/github.com/infobloxopen/protoc-gen-atlas-query-validate && dep ensure && GO111MODULE=off go install .
RUN go install github.com/infobloxopen/protoc-gen-atlas-validate@v0.4.2
RUN go install github.com/infobloxopen/protoc-gen-gorm@v0.21.0
RUN go install github.com/grpc-ecosystem/grpc-gateway/protoc-gen-grpc-gateway@v1.15.0

# build protoc-gen-swagger separately with atlas_patch
RUN go get github.com/go-openapi/spec && \
	rm -rf ${GOPATH}/src/github.com/grpc-ecosystem/ \
	&& mkdir -p ${GOPATH}/src/github.com/grpc-ecosystem/ && \
	cd ${GOPATH}/src/github.com/grpc-ecosystem && \
	git clone --single-branch -b atlas-patch https://github.com/infobloxopen/grpc-gateway.git && \
	cd grpc-gateway/protoc-gen-swagger && go build -o /out/usr/bin/protoc-gen-swagger main.go

# Download any projects that have proto-only packages, since go mod ignores those
RUN cd ${GOPATH}/src/github.com && mkdir -p googleapis/googleapis && cd googleapis/googleapis && \
    git init && git remote add origin https://github.com/googleapis/googleapis && git fetch && \
    git checkout origin/master -- *.proto

RUN mkdir -p /out/usr/bin

RUN rm -rf vendor/* ${GOPATH}/pkg/* \
    && install -c ${GOPATH}/bin/protoc-gen* /out/usr/bin/

# Copy in proto files, some are in non-go packages and are stored in third_party
# instead of being cloned from GitHub every build
COPY third_party/ /out/protos/go/src
RUN find ${GOPATH}/src -name "*.proto" -exec cp --parents {} /out/protos \;

RUN mkdir -p /out/protos && \
    find ${GOPATH}/src -name "*.proto" -exec cp --parents {} /out/protos \;

FROM alpine:3.14.2
RUN apk add --no-cache libstdc++ protobuf-dev
COPY --from=builder /out/usr /usr
COPY --from=builder /out/protos /

WORKDIR /go/src

# protoc as an entry point for all plugins with import paths set
ENTRYPOINT ["protoc", "-I.", \
    # required import paths for protoc-gen-grpc-gateway plugin
    "-Igithub.com/grpc-ecosystem/grpc-gateway/third_party/googleapis", \
    # required import paths for protoc-gen-swagger plugin
    "-Igithub.com/grpc-ecosystem/grpc-gateway", "-Igithub.com/grpc-ecosystem/grpc-gateway/protoc-gen-swagger/options", \
    # required import paths for protoc-gen-validate plugin
    "-Igithub.com/envoyproxy/protoc-gen-validate/validate", \
    # required import paths for go-proto-validators plugin
    "-Igithub.com/mwitkow/go-proto-validators", \
    # googleapis proto files
    "-Igithub.com/googleapis/googleapis", \
    # required import paths for protoc-gen-gorm plugin, Should add /proto path once updated
    "-Igithub.com/infobloxopen/protoc-gen-gorm", \
    # required import paths for protoc-gen-atlas-query-validate plugin
    "-Igithub.com/infobloxopen/protoc-gen-atlas-query-validate", \
    # required import paths for protoc-gen-preprocess plugin
    "-Igithub.com/infobloxopen/protoc-gen-preprocess", \
    # required import paths for protoc-gen-atlas-validate plugin
    "-Igithub.com/infobloxopen/protoc-gen-atlas-validate" \
]
