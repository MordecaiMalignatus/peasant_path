task default: :test

task :test do
  sh 'bundle exec rspec'
end

task :build do
  sh 'bundle exec ruby ./src/main.rb build 107917'
end

task :reset do
  sh 'rm -rf ~/.config/peasant_road'
  sh 'rm ./test.epub'
end

task :end_to_end do
  sh 'bundle exec ruby ./src/main.rb add https://www.royalroad.com/fiction/107917/sky-pride'
  sh 'bundle exec ruby ./src/main.rb pull'
  sh 'bundle exec ruby ./src/main.rb build 107917'
  sh 'open -a "Apple Books" "Sky Pride.epub"'
end
