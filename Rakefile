require_relative "lib/peasant_path/version"

task default: :test

task :test do
  sh "bundle exec rspec"
end

task :build do
  sh "bundle exec peasant_path build 107917"
end

task :install do
  sh "bundle exec gem build ./peasant_path.gemspec"
  sh "gem install ./peasant_path-#{PeasantPath::VERSION}.gem"
end

task :reset do
  sh "rm -rf ~/.config/peasant_path"
  sh 'rm -f "Sky Pride.epub"'
end

task :pull do
  sh "bundle exec peasant_path pull"
end

task :end_to_end do
  sh "bundle exec peasant_path add https://www.royalroad.com/fiction/107917/sky-pride"
  sh "bundle exec peasant_path pull"
  sh "bundle exec peasant_path build 107917"
  sh 'open -a "Apple Books" "Sky Pride.epub"'
end

task :fmt do
  sh "bundle exec rufo ."
end
