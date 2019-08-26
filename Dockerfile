FROM buildpack-deps:stretch AS base

# HACK
RUN mkdir -p /build/openssl
ARG OPENSSL_VERSION='1.0.1k'
ENV OPENSSL_VERSION=$OPENSSL_VERSION
RUN curl -s https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz | tar -C /build/openssl -xzf - && \
    cd /build/openssl/openssl-${OPENSSL_VERSION} && \
    ./Configure \
      --openssldir=/opt/openssl/openssl \
      shared linux-x86_64 && \
    make && make install_sw

# skip installing gem documentation
RUN set -eux; \
  mkdir -p /usr/local/etc; \
  { \
    echo 'install: --no-document'; \
    echo 'update: --no-document'; \
  } >> /usr/local/etc/gemrc

ARG RUBY_VERSION="2.4.6"

ENV RUBY_MAJOR 2.4
ENV RUBY_VERSION=$RUBY_VERSION
ENV RUBY_DOWNLOAD_SHA256 25da31b9815bfa9bba9f9b793c055a40a35c43c6adfb1fdbd81a09099f9b529c
ENV RUBYGEMS_VERSION 3.0.3

# Replacing pre-installed openssl from buildpack-deps
RUN set -eux; \
    rm -rf /usr/include/openssl; \
    rm -rf /usr/bin/openssl

# some of ruby's build scripts are written in ruby
#   we purge system ruby later to make sure our final image uses what we just built
RUN set -eux; \
  \
  savedAptMark="$(apt-mark showmanual)"; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    bison \
    dpkg-dev \
    libgdbm-dev \
    ruby \
  ; \
  rm -rf /var/lib/apt/lists/*; \
  \
  wget -O ruby.tar.xz "https://cache.ruby-lang.org/pub/ruby/${RUBY_MAJOR%-rc}/ruby-$RUBY_VERSION.tar.xz"; \
  echo "$RUBY_DOWNLOAD_SHA256 *ruby.tar.xz" | sha256sum --check --strict; \
  \
  mkdir -p /usr/src/ruby; \
  tar -xJf ruby.tar.xz -C /usr/src/ruby --strip-components=1; \
  rm ruby.tar.xz; \
  \
  cd /usr/src/ruby; \
  \
# hack in "ENABLE_PATH_CHECK" disabling to suppress:
#   warning: Insecure world writable dir
  { \
    echo '#define ENABLE_PATH_CHECK 0'; \
    echo; \
    cat file.c; \
  } > file.c.new; \
  mv file.c.new file.c; \
  \
  autoconf; \
  gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
  ./configure \
    --build="$gnuArch" \
    --disable-install-doc \
    --enable-shared \
    --with-openssl-dir="/opt/openssl/openssl" \
  ; \
  make -j "$(nproc)"; \
  make install; \
  \
  apt-mark auto '.*' > /dev/null; \
  apt-mark manual $savedAptMark > /dev/null; \
  find /usr/local -type f -executable -not \( -name '*tkinter*' \) -exec ldd '{}' ';' \
    | awk '/=>/ { print $(NF-1) }' \
    | sort -u \
    | xargs -r dpkg-query --search \
    | cut -d: -f1 \
    | sort -u \
    | xargs -r apt-mark manual \
  ; \
  apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
  \
  cd /; \
  rm -r /usr/src/ruby; \
# make sure bundled "rubygems" is older than RUBYGEMS_VERSION (https://github.com/docker-library/ruby/issues/246)
  ruby -e 'exit(Gem::Version.create(ENV["RUBYGEMS_VERSION"]) > Gem::Version.create(Gem::VERSION))'; \
  gem update --system "$RUBYGEMS_VERSION" && rm -r /root/.gem/; \
# verify we have no "ruby" packages installed
  ! dpkg -l | grep -i ruby; \
  [ "$(command -v ruby)" = '/usr/local/bin/ruby' ]; \
# rough smoke test
  ruby --version; \
  gem --version; \
  bundle --version

# install things globally, for great justice
# and don't create ".bundle" in all our apps
ENV GEM_HOME /usr/local/bundle
ENV BUNDLE_PATH="$GEM_HOME" \
  BUNDLE_SILENCE_ROOT_WARNING=1 \
  BUNDLE_APP_CONFIG="$GEM_HOME"
# path recommendation: https://github.com/bundler/bundler/pull/6469#issuecomment-383235438
ENV PATH $GEM_HOME/bin:$BUNDLE_PATH/gems/bin:$PATH
# adjust permissions of a few directories for running "gem install" as an arbitrary user
RUN mkdir -p "$GEM_HOME" && chmod 777 "$GEM_HOME"
# (BUNDLE_PATH = GEM_HOME, no need to mkdir/chown both)

CMD [ "irb" ]