class Admin::MasterController < ApplicationController

  layout 'admin'

  include Typus::Authentication
  include Typus::Format
  include Typus::Locale
  include Typus::Reloader

  if Typus::Configuration.options[:ssl]
    include SslRequirement
    ssl_required :index, :new, :create, :edit, :show, :update, :destroy, :toggle, :position, :relate, :unrelate
  end

  filter_parameter_logging :password

  before_filter :reload_config_et_roles

  before_filter :require_login

  before_filter :set_locale

  before_filter :set_resource
  before_filter :find_item, :only => [ :show, :edit, :update, :destroy, :toggle, :position, :relate, :unrelate ]

  before_filter :check_ownership_of_item, :only => [ :edit, :update, :toggle, :position, :relate, :unrelate, :destroy ]

  before_filter :check_if_user_can_perform_action_on_user, :only => [ :edit, :update, :toggle, :destroy ]
  before_filter :check_if_user_can_perform_action_on_resource

  before_filter :set_order, :only => [ :index ]
  before_filter :set_fields, :only => [ :index, :new, :edit, :create, :update, :show ]

  ##
  # This is the main index of the model. With the filters, conditions 
  # and more. You can get HTML, CSV and XML listings.
  #
  def index

    @conditions, @joins = @resource[:class].build_conditions(params)

    respond_to do |format|
      format.html { generate_html }
      @resource[:class].typus_export_formats.each do |f|
        format.send(f) { send("generate_#{f}") }
      end
    end

  rescue Exception => error
    error_handler(error)
  end

  ##
  # New item.
  #
  def new

    item_params = params.dup
    %w( controller action resource resource_id back_to selected ).each do |param|
      item_params.delete(param)
    end

    @item = @resource[:class].new(item_params.symbolize_keys)

    select_template :new

  end

  ##
  # Create new items. There's an special case when we create an 
  # item from another item. In this case, after the item is 
  # created we also create the relationship between these items. 
  #
  def create

    @item = @resource[:class].new(params[:item])

    if @item.attributes.include?(Typus.user_fk)
      @item.attributes = { Typus.user_fk => session[:typus_user_id] }
    end

    if @item.valid?
      create_with_back_to and return if params[:back_to]
      @item.save
      flash[:success] = _("{{model}} successfully created", :model => @resource[:class_name_humanized])
      if @resource[:class].typus_options_for(:index_after_save)
        redirect_to :action => 'index'
      else
        redirect_to :action => @resource[:class].typus_options_for(:default_action_on_item), :id => @item.id
      end
    else
      select_template :new
    end

  end

  ##
  # Edit an item.
  #
  def edit
    item_params = params.dup
    %w( action controller model model_id back_to id resource resource_id ).each { |p| item_params.delete(p) }
    # We assign the params passed trough the url
    @item.attributes = item_params
    @previous, @next = @item.previous_and_next(item_params)
    select_template :edit
  end

  ##
  # Show an item.
  #
  def show

    @previous, @next = @item.previous_and_next

    respond_to do |format|
      format.html { select_template :show }
      format.xml  { render :xml => @item }
    end

  end

  ##
  # Update an item.
  #
  def update
    if @item.update_attributes(params[:item])
      flash[:success] = _("{{model}} successfully updated.", :model => @resource[:class_name_humanized])
      if @resource[:class].typus_options_for(:index_after_save)
        redirect_to params[:back_to] ? "#{params[:back_to]}##{@resource[:self]}" : { :action => 'index' }
      else
        redirect_to :action => @resource[:class].typus_options_for(:default_action_on_item), :id => @item.id
      end
    else
      @previous, @next = @item.previous_and_next
      select_template :edit
    end
  end

  ##
  # Destroy an item.
  #
  def destroy
    @item.destroy
    flash[:success] = _("{{model}} successfully removed.", :model => @resource[:class_name_humanized])
    redirect_to :back
  rescue Exception => error
    error_handler(error, params.merge(:action => 'index', :id => nil))
  end

  ##
  # Toggle the status of an item.
  #
  def toggle
    if @resource[:class].typus_options_for(:toggle)
      @item.toggle!(params[:field])
      flash[:success] = _("{{model}} {{attribute}} changed.", 
                          :model => @resource[:class_name_humanized], 
                          :attribute => params[:field].humanize.downcase)
    else
      flash[:warning] = _("Toggle is disabled")
    end
    redirect_to :back
  end

  ##
  # Change item position. This only works if acts_as_list is 
  # installed. We can then move items:
  #
  #   params[:go] = 'move_to_top'
  #
  # Available positions are move_to_top, move_higher, move_lower, 
  # move_to_bottom.
  #
  def position
    @item.send(params[:go])
    flash[:success] = _("Record moved {{to}}.", :to => params[:go].gsub(/move_/, '').humanize.downcase)
    redirect_to :back
  end

  ##
  # Relate a model object to another.
  #
  def relate

    resource_class = params[:related][:model].constantize
    resource_tableized = params[:related][:model].tableize
    resource_id = params[:related][:id]
    resource = resource_class.find(resource_id)

    @item.send(params[:related][:model].tableize) << resource

    flash[:success] = _("{{model_a}} related to {{model_b}}", 
                        :model_a => resource_class.name.humanize, 
                        :model_b => @resource[:class_name_humanized])

    redirect_to :action => @resource[:class].typus_options_for(:default_action_on_item), 
                :id => @item.id, 
                :anchor => resource_tableized

  end

  ##
  # Remove relationship between models.
  #
  def unrelate

    resource_class = params[:resource].classify.constantize
    resource_tableized = params[:resource]
    resource_id = params[:resource_id]
    resource = resource_class.find(resource_id)

    case @resource[:class].reflect_on_association(params[:resource].to_sym).macro
    when :has_and_belongs_to_many
      @item.send(params[:resource]).delete(resource)
      flash[:success] = _("{{model_a}} unrelated from {{model_b}}", 
                          :model_a => resource_class.name.humanize, 
                          :model_b => @resource[:class_name_humanized])
    when :has_many
      resource.destroy
      flash[:success] = _("{{model_a}} removed from {{model_b}}", 
                          :model_a => resource_class.name.humanize, 
                          :model_b => @resource[:class_name_humanized])
    end

    redirect_to :controller => @resource[:self], 
                :action => @resource[:class].typus_options_for(:default_action_on_item), 
                :id => @item.id, 
                :anchor => resource_tableized

  end

private

  ##
  # Set current resource.
  #
  def set_resource

    resource = params[:controller].split('/').last

    @resource = {}
    @resource[:self] = resource
    @resource[:class] = resource.classify.constantize
    @resource[:table_name] = resource.classify.constantize.table_name
    @resource[:class_name] = resource.classify
    @resource[:class_name_humanized] = resource.humanize.singularize

  rescue Exception => error
    error_handler(error)
  end

  ##
  # Find model when performing an edit, update, destroy, relate, 
  # unrelate ...
  #
  def find_item
    @item = @resource[:class].find(params[:id])
  end

  ##
  # If item is owned by another user, we only can perform a 
  # show action on the item. Updated item is also blocked.
  #
  #   before_filter :check_ownership_of_item, :only => [ :edit, :update, :destroy ]
  #
  def check_ownership_of_item

    # If current_user is a root user, by-pass.
    return if @current_user.is_root?

    # If the current model doesn't include a key which relates it with the
    # current_user, by-pass.
    return unless @item.respond_to?(Typus.user_fk)

    # If item is owned by the user ...
    unless @item.send(Typus.user_fk) == session[:typus_user_id]
      flash[:notice] = _("Record owned by another user")
      redirect_to :action => 'show', :id => @item.id
    end

  end

  ##
  # Set fields on show action.
  #
  def set_fields
    @fields = case params[:action]
              when 'index'
                @resource[:class].typus_fields_for(:list)
              when 'new', 'edit', 'create', 'update'
                @resource[:class].typus_fields_for(:form)
              else
                @resource[:class].typus_fields_for(:show)
              end
  end

  ##
  # Set order
  #
  def set_order
    params[:sort_order] ||= 'desc'
    @order = params[:order_by] ? "#{@resource[:table_name]}.#{params[:order_by]} #{params[:sort_order]}" : @resource[:class].typus_order_by
  end

  ##
  # Select which template to render.
  #
  def select_template(template, resource = @resource[:self])
    folder = (File.exists?("app/views/admin/#{resource}/#{template}.html.erb")) ? resource : 'resources'
    render :template => "admin/#{folder}/#{template}"
  end

  ##
  # Used by create when params[:back_to] is defined.
  #
  def create_with_back_to

    if params[:resource] && params[:resource_id]

      resource_class = params[:resource].classify.constantize
      resource_id = params[:resource_id]
      resource = resource_class.find(resource_id)

      begin

        case @resource[:class].reflect_on_association(params[:resource].to_sym).macro
        when :has_and_belongs_to_many
          @item.save
          @item.send(params[:resource]) << resource
        when :has_many
          resource.send(@item.class.name.tableize).create(params[:item])
        end

      rescue

        # OPTIMIZE: Polimorphic
        resource.send(@item.class.name.tableize).create(params[:item])

      end

      flash[:success] = _("{{model_a}} successfully assigned to {{model_b}}.", 
                          :model_a => @item.class, 
                          :model_b => resource_class.name)
      redirect_to "#{params[:back_to]}##{@resource[:self]}"

    else

      @item.save
      flash[:success] = _("{{model}} successfully created", :model => @resource[:class_name_humanized])
      redirect_to "#{params[:back_to]}?#{params[:selected]}=#{@item.id}"

    end

  end

  ##
  # Error handler
  #
  def error_handler(error, path = admin_dashboard_path)
    raise error unless Rails.env.production?
    flash[:error] = "#{error.message} (#{@resource[:class]})"
    redirect_to path
  end

end