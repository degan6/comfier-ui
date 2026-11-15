class ApiDocumentationController < ApplicationController
  include SettingsNav

  def show
    @markdown = Rails.root.join('docs/USER_API.md').read.gsub('https://comfier.example.com', request.base_url)
    respond_to do |format|
      format.html
      format.text { render plain: @markdown }
    end
  end
end
