task default: :test

task :test do
  sh "bundle exec rspec"
end

task :build do
  sh "bundle exec peasant_road build 107917"
end

task :install do 
  sh 'bundle exec gem build ./peasant_road.gemspec'
  sh 'gem install ./peasant_road-0.1.0.gem'
end

task :reset do
  sh "rm -rf ~/.config/peasant_road"
  sh 'rm -f "Sky Pride.epub"'
end

task :pull do
  sh "bundle exec peasant_road pull"
end

task :end_to_end do
  sh "bundle exec peasant_road add https://www.royalroad.com/fiction/107917/sky-pride"
  sh "bundle exec peasant_road pull"
  sh "bundle exec peasant_road build 107917"
  sh 'open -a "Apple Books" "Sky Pride.epub"'
end

task :fmt do
  sh "bundle exec rufo ."
end
