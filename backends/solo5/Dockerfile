# Development feasibility backend only; no TC0/Solo5 determinism qualification.
FROM alpine@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8
RUN apk add --no-cache build-base linux-headers libseccomp-dev pkgconf bash coreutils git
COPY . /opt/solo5
WORKDIR /opt/solo5
RUN ./configure.sh --prefix=/opt/solo5-install && make -j2 && make install
ARG FENRIR_BUILD_SPEC_SHA256=unrecorded
LABEL org.fenrir.solo5.commit="38e0c348be231a2a3c59510a5caabf562792679f" \
      org.fenrir.buildspec.sha256="$FENRIR_BUILD_SPEC_SHA256"
# No default guest execution or network devices.
CMD ["/opt/solo5/tenders/spt/solo5-spt", "--help"]
