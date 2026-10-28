# frozen_string_literal: true

require "net/http"
require_relative "corpus"

module SchemuraiBenchmark
  module RealWorld
    class Fetcher
      def initialize(root: Corpus::ROOT)
        @root = root
      end

      def fetch_all
        Dir[File.join(@root, "schemas", "*", "source.json")].sort.each do |source|
          entry = JSON.parse(File.read(source))
          directory = File.dirname(source)
          license = fetch_bytes(entry.fetch("license"))
          approved = File.binread(File.join(directory, "LICENSE"))
          unless license == approved && Digest::SHA256.hexdigest(license) == entry.fetch("license").fetch("sha256")
            raise "license changed: #{entry.fetch("id")}; review LICENSE and source.json together"
          end

          bytes = fetch_bytes(entry.fetch("schema"))
          schema = JSON.parse(bytes)
          unless schema.fetch("$schema") == "http://json-schema.org/draft-07/schema#"
            raise "unreviewed dialect: #{entry.fetch("id")}"
          end
          check_references(schema)
          receipt = {source: entry, sha256: Digest::SHA256.hexdigest(bytes)}
          # Publish the receipt last: interrupted downloads cannot bless a stale
          # schema after Renovate changes the source pin.
          File.binwrite(File.join(directory, "schema.json"), bytes)
          File.write(File.join(directory, "receipt.json"), JSON.pretty_generate(receipt) + "\n")
          puts "Fetched #{entry.fetch("id")} at #{entry.fetch("schema").fetch("revision")} (#{receipt.fetch(:sha256)})"
        end
      end

      private def fetch_bytes(dependency)
        repository = dependency.fetch("repository")
        revision = dependency.fetch("revision")
        path = dependency.fetch("path")
        unless /\A[\w.-]+\/[\w.-]+\z/.match?(repository) && /\A[0-9a-f]{40}\z/.match?(revision) && /\A[\w.\/-]+\z/.match?(path)
          raise "invalid pinned GitHub source"
        end
        uri = URI("https://raw.githubusercontent.com/#{repository}/#{revision}/#{path}")
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
          http.get(uri.request_uri)
        end
        raise "fetch failed: #{repository}/#{path}: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        response.body
      end

      private def check_references(node)
        case node
        when Hash
          if node["$ref"].is_a?(String) && !node.fetch("$ref").start_with?("#")
            raise "external references must be pinned before adding this schema: #{node.fetch("$ref")}"
          end
          node.each_value { |child| check_references(child) }
        when Array
          node.each { |child| check_references(child) }
        end
      end
    end
  end
end
