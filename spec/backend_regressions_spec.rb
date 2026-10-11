# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/backend_regressions"

RSpec.describe "backend regression coverage", :regression do
  %i[ruby vm].each do |backend|
    context "with the #{backend} backend" do
      it_behaves_like "backend regressions", backend
    end
  end
end
