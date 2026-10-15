# frozen_string_literal: true

module Schemurai
  module Internal
    module JsonPointer
      module_function def escape(segment)
        segment.to_s.gsub("~", "~0").gsub("/", "~1")
      end
    end
  end
end
