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
        # Store a single index until a collision needs a bucket array.
        index = 0
        while index < values.length
          item = values[index]
          fingerprint = json_fingerprint(item)
          if (bucket = buckets[fingerprint])
            if bucket.is_a?(Integer)
              return false if json_equal?(values[bucket], item)

              buckets[fingerprint] = [bucket, index]
            else
              return false if bucket.any? { |previous| json_equal?(values[previous], item) }

              bucket << index
            end
          else
            buckets[fingerprint] = index
          end
          index += 1
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
          # Mask before multiplication to keep intermediate values immediate
          # integers; hash each step to retain order without temporary arrays.
          fingerprint = value.class.hash
          value.each { |item| fingerprint = (((fingerprint & 0x1fffffff) * 31) ^ json_fingerprint(item)).hash }
          fingerprint
        when Hash
          # Object key order is immaterial. Hash collisions are resolved using
          # json_equal?, so this fingerprint never decides equality itself.
          entries = 0
          value.each_pair { |key, item| entries ^= (((key.hash & 0x1fffffff) * 31) ^ json_fingerprint(item)).hash }
          (value.class.hash ^ value.length ^ entries).hash
        else
          value.hash
        end
      end
    end
  end
end
