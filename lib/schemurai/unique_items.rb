# frozen_string_literal: true

module Schemurai
  module Internal
    module UniqueItems
      private def unique_items?(values)
        # Avoid building an index for small arrays and early duplicates.
        if values.length <= 16
          values.each_with_index do |item, index|
            index.times { |previous| return false if json_equal?(values[previous], item) }
          end
          return true
        end

        buckets = {}
        values.each do |item|
          fingerprint = json_fingerprint(item)
          if (bucket = buckets[fingerprint])
            return false if bucket.any? { |previous| json_equal?(previous, item) }

            bucket << item
          else
            buckets[fingerprint] = [item]
          end
        end
        true
      end

      private def json_fingerprint(value)
        case value
        when Numeric
          # JSON numbers compare across Integer/Float. Converting integral
          # floats to integers also preserves precision for large integers.
          return value.hash if value.is_a?(Integer)

          number = value.to_f
          (number.finite? && number == number.to_i) ? number.to_i.hash : number.hash
        when Array
          [value.class, value.map { |item| json_fingerprint(item) }].hash
        when Hash
          # Object key order is immaterial. Hash collisions are resolved using
          # json_equal?, so this fingerprint never decides equality itself.
          entries = value.reduce(0) { |hash, (key, item)| hash ^ [key, json_fingerprint(item)].hash }
          [value.class, value.length, entries].hash
        else
          [value.class, value].hash
        end
      end
    end
  end
end
