module Admin
  class ActivityLogsController < BaseController
    PER_PAGE = 50

    def index
      @kind = params[:kind].presence_in(ActivityLog.kinds.keys)
      @q = params[:q].to_s.strip
      scope = ActivityLog.recent.includes(:user, :subject)
      scope = scope.where(kind: @kind) if @kind
      scope = scope.search(@q)
      @pagy, @activity_logs = pagy(:offset, scope, limit: PER_PAGE)
    end

    def show
      @activity_log = ActivityLog.find(params[:id])
    end
  end
end
