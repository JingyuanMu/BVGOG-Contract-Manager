class ContractsController < ApplicationController
  before_action :set_contract, only: %i[show edit update destroy]

  def expiry_reminder
    @contract = Contract.find(params[:id])
    @contract.send_expiry_reminder
    respond_to do |format|
      format.html { redirect_to contract_url(@contract), notice: 'Expiry reminder sucessfully sent.' }
      format.json { render :show, status: :ok, location: @contract }
    end
  end

  # GET /contracts or /contracts.json
  def index
    add_breadcrumb 'Contracts', contracts_path
    # Sort contracts
    @contracts = sort_contracts.page params[:page]
    print reports_path
    # Filter contracts based on allowed entities if user is level 3
    @contracts = @contracts.where(entity_id: current_user.entities.pluck(:id)) if current_user.level == UserLevel::THREE
    # Search contracts
    @contracts = search_contracts(@contracts) if params[:search].present?
    puts params[:search].inspect
  end

  # GET /contracts/1 or /contracts/1.json
  def show
    add_breadcrumb 'Contracts', contracts_path
    add_breadcrumb @contract.title, contract_path(@contract)
  end

  # GET /contracts/new
  def new
    add_breadcrumb 'Contracts', contracts_path
    add_breadcrumb 'New Contract', new_contract_path
    @contract = Contract.new
  end

  # GET /contracts/1/edit
  def edit
    add_breadcrumb 'Contracts', contracts_path
    add_breadcrumb @contract.title, contract_path(@contract)
    add_breadcrumb 'Edit', edit_contract_path(@contract)
  end

  # POST /contracts or /contracts.json
  def create
    add_breadcrumb 'Contracts', contracts_path
    add_breadcrumb 'New Contract', new_contract_path

    contract_documents_upload = params[:contract][:contract_documents]
    # Delete the contract_documents from the params
    # so that it doesn't get saved as a contract attribute
    params[:contract].delete(:contract_documents)

    @contract = Contract.new(contract_params.merge(contract_status: ContractStatus::IN_PROGRESS))

    respond_to do |format|
      ActiveRecord::Base.transaction do
        begin
          OSO.authorize(current_user, 'write', @contract)
          handle_if_new_vendor
          if @contract.point_of_contact_id.present? && User.find(@contract.point_of_contact_id).redirect_user_id.present?
            @contract.errors.add(:base,
                                 User.find(@contract.point_of_contact_id).full_name + ' is not active, use ' + User.find(User.find(@contract.point_of_contact_id).redirect_user_id).full_name + ' instead')
            format.html { render :new, status: :unprocessable_entity }
            format.json { render json: @contract.errors, status: :unprocessable_entity }
          elsif !User.find(@contract.point_of_contact_id).entities.include?(@contract.entity)
            @contract.errors.add(:base,
                                 User.find(@contract.point_of_contact_id).full_name + ' is not associated with ' + @contract.entity.name)
            format.html { render :new, status: :unprocessable_entity }
            format.json { render json: @contract.errors, status: :unprocessable_entity }
          elsif @contract.save
            handle_contract_documents(contract_documents_upload) if contract_documents_upload.present?
            format.html { redirect_to contract_url(@contract), notice: 'Contract was successfully created.' }
            format.json { render :show, status: :created, location: @contract }
          else
            format.html { render :new, status: :unprocessable_entity }
            format.json { render json: @contract.errors, status: :unprocessable_entity }
          end
        end
      rescue StandardError => e
        # If error type is Oso::ForbiddenError, then the user is not authorized
        if e.instance_of?(Oso::ForbiddenError)
          status = :unauthorized
          @contract.errors.add(:base, 'You are not authorized to create a contract')
          message = 'You are not authorized to create a contract'
        else
          status = :unprocessable_entity
          message = e.message
        end
        format.html { redirect_to contracts_path, alert: message }
      end
    end
  end

  # PATCH/PUT /contracts/1 or /contracts/1.json
  def update
    add_breadcrumb 'Contracts', contracts_path
    add_breadcrumb @contract.title, contract_path(@contract)
    add_breadcrumb 'Edit', edit_contract_path(@contract)

    handle_if_new_vendor
    contract_documents_upload = params[:contract][:contract_documents]
    # Delete the contract_documents from the params
    # so that it doesn't get saved as a contract attribute
    params[:contract].delete(:contract_documents)

    respond_to do |format|
      ActiveRecord::Base.transaction do
        OSO.authorize(current_user, 'edit', @contract)
        if contract_params[:point_of_contact_id].present? && User.find(contract_params[:point_of_contact_id]).redirect_user_id.present?
          @contract.errors.add(:base,
                               User.find(contract_params[:point_of_contact_id]).full_name + ' is not active, use ' + User.find(User.find(contract_params[:point_of_contact_id]).redirect_user_id).full_name + ' instead')
          format.html { render :edit, status: :unprocessable_entity }
          format.json { render json: @contract.errors, status: :unprocessable_entity }

        # Excuse this monster if statement, it's just checking if the user is associated with the entity, and for
        # some reason nested-if statements don't work here when you use format (ie. UnkownFormat error)
        elsif !User.find(contract_params[:point_of_contact_id].present? ? contract_params[:point_of_contact_id] : @contract.point_of_contact_id).entities.include?(Entity.find(contract_params[:entity_id].present? ? contract_params[:entity_id] : @contract.entity_id))
          @contract.errors.add(:base,
                               User.find(contract_params[:point_of_contact_id].present? ? contract_params[:point_of_contact_id] : @contract.point_of_contact_id).full_name + ' is not associated with ' + Entity.find(contract_params[:entity_id].present? ? contract_params[:entity_id] : @contract.entity_id).name)
          format.html { render :edit, status: :unprocessable_entity }
          format.json { render json: @contract.errors, status: :unprocessable_entity }
        elsif @contract.update(contract_params)
          handle_contract_documents(contract_documents_upload) if contract_documents_upload.present?
          puts 'Contract updated successfully'
          format.html { redirect_to contract_url(@contract), notice: 'Contract was successfully updated.' }
          format.json { render :show, status: :ok, location: @contract }
        else
          format.html { render :edit, status: :unprocessable_entity }
          format.json { render json: @contract.errors, status: :unprocessable_entity }
        end
      end

    rescue StandardError => e
      @contract.reload
      print e
      # If error type is Oso::ForbiddenError, then the user is not authorized
      if e.instance_of?(Oso::ForbiddenError)
        status = :unauthorized
        @contract.errors.add(:base, 'You are not authorized to update this contract')
        message = 'You are not authorized to update this contract'
      else
        status = :unprocessable_entity
        message = e.message
      end
      # Rollback the transaction
      format.html { redirect_to contract_url(@contract), alert: message }
    end
  end

  # DELETE /contracts/1 or /contracts/1.json
  def destroy
    @contract.destroy

    respond_to do |format|
      format.html { redirect_to contracts_url, notice: 'Contract was successfully destroyed.' }
      format.json { head :no_content }
    end
  end

  def get_file
    contract_document = ContractDocument.find(params[:id])
    send_file contract_document.file.path, type: contract_document.file_content_type, disposition: :inline
  end

  private

  # Use callbacks to share common setup or constraints between actions.
  def set_contract
    @contract = Contract.find(params[:id])
  end

  def set_users
    @users = User.all
  end

  # Only allow a list of trusted parameters through.
  def contract_params
    allowed = %i[
      title
      description
      key_words
      starts_at
      ends_at
      contract_status
      entity_id
      program_id
      point_of_contact_id
      vendor_id
      amount_dollar
      amount_duration
      initial_term_amount
      initial_term_duration
      end_trigger
      contract_type
      requires_rebid
      number
      contract_documents
    ]
    params.require(:contract).permit(allowed)
  end

  def sort_contracts
    # Sorts by the query string parameter "sort"
    # Since some columns are combinations or associations, we need to handle them separately
    asc = params[:order] || 'asc'
    case params[:sort]
    when 'point_of_contact'
      # Sort by the name of the point of contact
      Contract.joins(:point_of_contact).order("users.last_name #{asc}").order("users.first_name #{asc}")
    when 'vendor'
      Contract.joins(:vendor).order("vendors.name #{asc}")
    else
      begin
        # Sort by the specified column and direction
        params[:sort] ? Contract.order(params[:sort] => asc.to_sym) : Contract.order(created_at: :asc)
      rescue ActiveRecord::StatementInvalid
        # Otherwise, sort by title
        # TODO: should we reconsider this?
        Contract.order(title: :asc)
      end
    end

    # Returns the sorted contracts
  end

  def search_contracts(contracts)
    # Search by the query string parameter "search"
    # Search in "title", "description", and "key_words"
    contracts.where('title LIKE ? OR description LIKE ? OR key_words LIKE ?', "%#{params[:search]}%",
                    "%#{params[:search]}%", "%#{params[:search]}%")
  end

  def handle_if_new_vendor
    # Check if the vendor is new
    if params[:contract][:vendor_id] == 'new'
      # Create a new vendor
      # Make vendor name Name Case
      params[:contract][:new_vendor_name] = params[:contract][:new_vendor_name].titlecase
      vendor = Vendor.new(name: params[:contract][:new_vendor_name])
      # If the vendor is saved successfully
      if vendor.save
        # Set the contract's vendor to the new vendor
        @contract.vendor = vendor
      end
    end
    # Remove the new_vendor_name parameter
    params[:contract].delete(:new_vendor_name)
  end

  # TODO: This is a temporary solution
  # File upload is a seperate issue that will be handled with a dropzone
  def handle_contract_documents(contract_documents_upload)
    for doc in contract_documents_upload
      next unless doc.present?

      # Create a file name for the official file
      official_file_name = contract_document_filename(@contract, File.extname(doc.original_filename))
      # Write the file to the if the contract does not have
      # a contract_document with the same orig_file_name
      next if @contract.contract_documents.find_by(orig_file_name: doc.original_filename)

      # Write the file to the filesystem
      bvcog_config = BvcogConfig.last
      File.open(Rails.root.join(bvcog_config.contracts_path, official_file_name), 'wb') do |file|
        file.write(doc.read)
      end
      # Create a new contract_document
      contract_document = ContractDocument.new(
        orig_file_name: doc.original_filename,
        file_name: official_file_name,
        full_path: Rails.root.join(bvcog_config.contracts_path, official_file_name).to_s
      )
      # Add the contract_document to the contract
      @contract.contract_documents << contract_document
    end
  end
end
