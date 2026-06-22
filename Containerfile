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

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates libicu-dev \
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
