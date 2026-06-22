require_relative "lib/peasant_path/version"
require "rbconfig"

def configure_ffi_icu_paths
  return unless RbConfig::CONFIG["host_os"].include?("darwin")

  lib_dir = [
    "/opt/homebrew/opt/icu4c@78/lib",
    "/usr/local/opt/icu4c@78/lib",
    "/opt/homebrew/opt/icu4c/lib",
    "/usr/local/opt/icu4c/lib",
  ].find { |path| File.directory?(path) }
  return unless lib_dir

  ENV["FFI_ICU_LIB"] = lib_dir if ENV["FFI_ICU_LIB"].to_s.empty?

  fallback_paths = ENV["DYLD_FALLBACK_LIBRARY_PATH"].to_s.split(File::PATH_SEPARATOR)
  fallback_paths.unshift(lib_dir) unless fallback_paths.include?(lib_dir)
  ENV["DYLD_FALLBACK_LIBRARY_PATH"] = fallback_paths.reject(&:empty?).join(File::PATH_SEPARATOR)
end

configure_ffi_icu_paths

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
