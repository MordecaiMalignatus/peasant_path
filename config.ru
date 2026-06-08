require_relative "lib/peasant_road"
require_relative "lib/peasant_road/web"

PeasantRoad::Web.start_scheduler!
run PeasantRoad::Web
