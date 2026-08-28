FROM ruby:4.0.1-slim AS builder

WORKDIR /app

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential ca-certificates libicu-dev pkg-config \
  && rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock peasant_path.gemspec ./
COPY lib/peasant_path/version.rb ./lib/peasant_path/version.rb

RUN bundle config set without 'development test' \
  && bundle install

COPY . .

RUN bundle exec gem build ./peasant_path.gemspec \
  && gem install --local ./peasant_path-*.gem

FROM ruby:4.0.1-slim

ENV PEASANT_PATH_SCHEDULER=internal \
    PEASANT_PATH_INTERVAL_HOURS=6 \
    HOME=/data

WORKDIR /app

# FanFictionNetClient drives headless Chrome via ferrum, so a real Chrome
# binary is a runtime dependency here too, not just a build one. The plain
# "chromium"/"chromium-browser" apt packages resolve to a transitional snap
# wrapper on current Debian/Ubuntu, which doesn't run in a container without
# snapd — installing Google Chrome's official .deb directly avoids that, and
# needs neither an apt repo nor a signing key. FanFictionNetClient always
# launches Chrome with --no-sandbox, so no extra container capabilities are
# needed to run it as the unprivileged peasant_path user below.
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl libicu-dev \
  && arch="$(dpkg --print-architecture)" \
  && curl -sL -o /tmp/google-chrome.deb "https://dl.google.com/linux/direct/google-chrome-stable_current_${arch}.deb" \
  && apt-get install -y --no-install-recommends /tmp/google-chrome.deb \
  && rm -f /tmp/google-chrome.deb \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --create-home --home-dir /data --shell /usr/sbin/nologin peasant_path \
  && mkdir -p /data/.config/peasant_path \
  && chown -R peasant_path:peasant_path /data

COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY --from=builder /app/config.ru /app/config.ru

USER peasant_path

EXPOSE 4567
VOLUME ["/data"]

CMD ["peasant_path", "serve", "--bind", "0.0.0.0", "--port", "4567"]
