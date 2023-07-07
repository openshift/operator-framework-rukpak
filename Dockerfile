FROM registry.ci.openshift.org/ocp/builder:rhel-8-golang-1.19-openshift-4.14 AS builder

# copy just enough of the git repo to parse HEAD, used to record version in OLM binaries
COPY .git/HEAD .git/HEAD
COPY .git/refs/heads/. .git/refs/heads
RUN mkdir -p .git/objects

WORKDIR /build
COPY . .
RUN make build

FROM registry.ci.openshift.org/ocp/4.14:base

COPY --from=builder /build/bin/core /
COPY --from=builder /build/bin/unpack /
COPY --from=builder /build/bin/webhooks /
COPY --from=builder /build/bin/helm /
COPY --from=builder /build/bin/crdvalidator /
COPY --from=builder /build/bin/rukpakctl /
USER 1001

LABEL io.k8s.display-name="OpenShift RukPak" \
      io.k8s.description="This is a component of OpenShift Container Platform and manages the lifecycle of operators." \
      io.openshift.tags="openshift" \
      summary="This is a component of OpenShift Container Platform and manages the lifecycle of operators." \
      maintainer="Odin Team <aos-odin@redhat.com>"
