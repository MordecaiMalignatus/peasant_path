require_relative "lib/peasant_path"
require_relative "lib/peasant_path/web"

PeasantPath::Web.start_scheduler!
run PeasantPath::Web
