FROM public.ecr.aws/docker/library/ruby:3.2.3-bullseye

RUN mkdir /app
WORKDIR /app
COPY redis-rack.gemspec Gemfile /app/
COPY lib/redis/rack/version.rb /app/lib/redis/rack/version.rb
RUN bundle install
COPY . /app/
