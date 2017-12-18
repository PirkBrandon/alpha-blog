require 'csv'

class InvoiceService
  class InvoiceAlreadyCommittedError < StandardError
  end

  class << self
    @_instance = nil

    # @return [InvoiceService]
    def instance
      @_instance ||= new
    end
  end

  def delete_line_item(invoice, line_item)
    raise InvoiceAlreadyCommittedError if invoice.commited_at.present?

    Invoice.transaction do
      line_item.destroy!
      recalculate_invoice_totals(invoice)
    end
  end

  def add_line_item(invoice, line_item)
    raise InvoiceAlreadyCommittedError if invoice.commited_at.present?
    raise 'Line item must be new' unless line_item.new_record?

    if invoice.manual_receipt_number.present?
      line_item.name = "Handbeleg #{invoice.manual_receipt_number} vom #{I18n.l invoice.manual_receipt_date}"
    else
      if line_item.gross_amount_per_item &&
        invoice.register.net_amount_input &&
        !invoice.cancels_invoice

        line_item.gross_amount_per_item = calculate_gross_from_net_amount(line_item)
      end
    end

    line_item.invoice = invoice
    line_item.save!

    recalculate_invoice_totals(invoice)

    line_item
  end

  def calculate_gross_from_net_amount(line_item)
    line_item.gross_amount_per_item * ((100.0 + line_item.tax_percentage) / 100.0)
  end

  def mark_as_manual_receipt(invoice, invoice_params)
    unless invoice.manual_receipt_number
      invoice.update_attributes!(
        invoice_params.permit(:manual_receipt_number, :manual_receipt_date)
      )
    end
  end

  def recalculate_invoice_totals(invoice)
    invoice.reload

    current_gross_total = BigDecimal('0')
    current_net_total   = BigDecimal('0')

    invoice.line_items(true).each do |line_item|
      current_gross_total = current_gross_total + line_item.calculated_gross_total
      current_net_total   = current_net_total   + line_item.calculated_net_total
    end

    invoice.gross_total = current_gross_total
    invoice.net_total   = current_net_total

    invoice.save!
  end

  def write_gross_amounts_for_tax(invoice)
    tax_groups = invoice.totals_per_tax_group

    invoice.gross_amount_tax_normal = if tax_groups[20].present?
      tax_groups[20].gross_total
    else
      0
    end

    invoice.gross_amount_tax_reduced_1 = if tax_groups[10].present?
      tax_groups[10].gross_total
    else
      0
    end

    invoice.gross_amount_tax_reduced_2 = if tax_groups[13].present?
      tax_groups[13].gross_total
    else
      0
   end

    invoice.gross_amount_tax_special = if tax_groups[19].present?
     tax_groups[19].gross_total
   else
     0
   end

    invoice.gross_amount_tax_zero = if tax_groups[0].present?
      tax_groups[0].gross_total
    else
      0
    end

    invoice
  end

  def assign_customer(company, params)
    invoice  = company.invoices.find_by_id!(params[:id])
    customer = company.customers.find_by_id!(params[:company_customer][:id])

    invoice.customer = customer
    invoice.save!

    invoice
  end

  def withdraw_customer(company, params)
    invoice = company.invoices.find_by_id!(params[:id])

    invoice.customer = nil
    invoice.save!

    invoice
  end

  def create_and_assign_customer(company, params)
    invoice  = company.invoices.find_by_id!(params[:id])

    customer = CompanyCustomerService.new.create(company, params)

    invoice.customer = customer
    invoice.save!

    invoice
  end

  def update_and_assign_customer(company, params)
    invoice  = company.invoices.find_by_id!(params[:id])

    customer = company.customers.find_by_company_customer_id(
      params[:company_customer][:company_customer_id]
    )

    customer.update_attributes!(params[:company_customer].permit(CompanyCustomerService.new.column_names))

    invoice.customer = customer
    invoice.save!

    invoice
  end

  # Generates a new invoice that
  # - is part of the export protocol
  # - will not change the signed counter
  # - will not change the balance of the register
  #
  # @param [JournalPosition] position
  def commit_journal_position(company, user, register, position)
    invoice = company.invoices.new(user: user, register: register)
    invoice.payment_method = 'ledger'
    invoice.test_receipt = user.test_receipt
    invoice.save!

    if position.type == 'in'
      add_line_item(invoice, InvoiceLineItem.new(
        name:           "Bareinzahlung #{ position.note }",
        quantity:       1,
        tax_percentage: 0,
        gross_amount_per_item: position.amount,
        product_description: ""
      ))
    else
      add_line_item(invoice, InvoiceLineItem.new(
        name:           "Barentnahme #{ position.note }",
        quantity:       1,
        tax_percentage: 0,
        gross_amount_per_item: (0 - position.amount),
        product_description: ""
      ))
    end

    invoice
  end

  # Invoice numbers MUST only be incremented by using this method.
  # The serialization point is the register by using SELECT ... FOR UPDATE
  def commit(invoice, params = {})
    raise InvoiceAlreadyCommittedError if invoice.commited_at.present?

    register_id = invoice.register_id

    invoice = write_gross_amounts_for_tax(invoice)

    #Workaround for specs
    invoice.payment_method = params[:payment_method] if params[:payment_method]

    Invoice.transaction do
      register = Register.where(id: register_id).lock(true).first

      # The tick is NOT the invoice number, it just makes sure that no other
      # Transaction can read this register in the meantime.
      register.invoice_number_ticket = register.invoice_number_ticket + 1

      invoice.commited_at = Time.now
      invoice.number      = invoice.register.invoices.where('commited_at IS NOT NULL').count + 1

      if ['cash', 'ledger'].include?( invoice.payment_method )
        invoice.register_journal_delta = invoice.gross_total
      end

      invoice.save!
      register.save!

      invoice
    end

    # This is here since all the receipt handling is very messy in the controllers,
    # we have multiple entry points.
  end

  def cancel(invoice)
    raise 'Invoice must be committed' unless invoice.commited_at

    user     = invoice.user
    company  = invoice.company
    register = invoice.register

    cancelling_invoice = company.invoices.create!(
      cancels_invoice: invoice,
      user:                  user,
      register:              register,
      manual_receipt_number: invoice.manual_receipt_number,
      manual_receipt_date:   invoice.manual_receipt_date,
      test_receipt:          invoice.test_receipt,
      payment_method:        invoice.payment_method
    )

    invoice.line_items.each do |line_item|
      cancelling_line_item = InvoiceLineItem.new(
        name:           "Stornierung #{ line_item.name }",
        quantity:       line_item.quantity,
        tax_percentage: line_item.tax_percentage,
        gross_amount_per_item: 0 - line_item.gross_amount_per_item
      )

      add_line_item(cancelling_invoice, cancelling_line_item)
    end

    cancelling_invoice.save!

    cancelling_invoice
  end

  # @param [[Invoice]] invoices
  # @param [Bool] excel
  def export_as_csv(invoices, excel = false)
    bom     = ''
    col_sep = ''

    if !!excel
      bom     << "\xEF\xBB\xBF"
      col_sep << ";"
    else
      bom     << ""
      col_sep << ","
    end

    CSV.generate(:col_sep => col_sep) do |csv|
      csv << [
        bom +
        'Belegnummer',
        'Kassanummer',
        'Benutzernummer',
        'Datum',
        'Zahlungsart',
        'Netto Betrag',
        'Brutto Betrag',
        'Versteuert 20',
        'Versteuert 10',
        'Versteuert 13',
        'Versteuert 19',
        'Handbeleg',
        'Testbeleg',

        'Kunde Vorname',
        'Kunde Nachname',
        'Kunde Adresse',
        'Kunde Stadt',
        'Kunde PLZ',
        'Kunde Land',
        'Kunde Telefon',
        'Kunde Fax',
        'Kunde UID',
        'Kunde Steuernummer',
        'Anmerkung'
      ]


      invoices.each do |invoice|
        test_receipt   = invoice.test_receipt?         ? '1' : '0'
        note           = invoice.line_items.first.name if invoice.payment_method == "ledger"

        cc_first_name = (cc = invoice.customer) ? cc.first_name   : ''
        cc_last_name  = (cc = invoice.customer) ? cc.last_name    : ''
        cc_address    = (cc = invoice.customer) ? cc.address      : ''
        cc_city       = (cc = invoice.customer) ? cc.city         : ''
        cc_zip        = (cc = invoice.customer) ? cc.zip          : ''
        cc_country    = (cc = invoice.customer) ? cc.country      : ''
        cc_phone      = (cc = invoice.customer) ? cc.phone_number : ''
        cc_fax        = (cc = invoice.customer) ? cc.fax_number   : ''
        cc_uid        = (cc = invoice.customer) ? cc.uid          : ''
        cc_tax_number = (cc = invoice.customer) ? cc.tax_number   : ''

        csv << [
          invoice.number,
          invoice.register.number_with_prefix,
          (invoice.user && invoice.user.id),
          I18n.l(invoice.commited_at, format: :short_without_time),
          format_payment_method(invoice.payment_method),
          format_currency(invoice.net_total),
          format_currency(invoice.gross_total),
          format_currency(invoice.gross_amount_tax_normal),
          format_currency(invoice.gross_amount_tax_reduced_1),
          format_currency(invoice.gross_amount_tax_reduced_2),
          format_currency(invoice.gross_amount_tax_special),
          invoice.manual_receipt_number,
          test_receipt,

          cc_first_name,
          cc_last_name,
          cc_address,
          cc_city,
          cc_zip,
          cc_country,
          cc_phone,
          cc_fax,
          cc_uid,
          cc_tax_number,
          note
        ]
      end
    end
  end

  def filter(company_id, first_invoice_date, params, request_type: nil)

    gross_total_min = params['gross-total-min'].presence
    gross_total_max = params['gross-total-max'].presence

    min_date = (params['daterange-from'].presence || first_invoice_date).to_datetime
    max_date = (params['daterange-to'].presence || Date.today).to_datetime.end_of_day

    #Build query via AREL
    invoice = Invoice.arel_table

    #SELECT
    query = invoice.project('id, register_id, user_id, number, commited_at, gross_total, manual_receipt_number, test_receipt, cancels_invoice_id, payed, payment_method, company_customer_id, net_total, gross_amount_tax_normal, gross_amount_tax_reduced_1, gross_amount_tax_reduced_2, gross_amount_tax_zero, gross_amount_tax_special, company_id, kind')

    #Relation
    query = query.where(invoice[:company_id].eq(company_id))

    if register_id = params[:register_id].presence
      query = query.where(invoice[:register_id].eq(register_id))
    end

    if customer_id = params[:selected_customer_id].presence
      query = query.where(invoice[:company_customer_id].eq(customer_id))
    end

    #Conditions (WHERE)
    query = query.where(invoice[:commited_at].not_eq(nil))

    query = query.where(invoice[:number].eq(params[:number])) if params[:number].present?

    query = query.where(invoice[:gross_total].gteq(gross_total_min.gsub(',', '.'))) if gross_total_min
    query = query.where(invoice[:gross_total].lteq(gross_total_max.gsub(',', '.'))) if gross_total_max

    query = query.where(invoice[:test_receipt].eq(params[:test_receipt] == "true")) unless params[:test_receipt].blank?

    query = query.where(invoice[:commited_at].gteq(min_date))
    query = query.where(invoice[:commited_at].lteq(max_date))

    query = query.where(invoice[:payment_method].eq(params[:payment_method])) if params[:payment_method].present?

    unless params[:manual_receipt].blank?
      query = if params[:manual_receipt] == "true"
        query.where(invoice[:manual_receipt_number].not_eq(nil))
      else
        query.where(invoice[:manual_receipt_number].eq(nil))
      end
    end

    query = query.order(invoice[:id].desc)

    case request_type
    when nil, 'text/html'
      query.limit = 100
      when 'text/csv' # including excel
    else
      throw "Unknown request type: #{ request_type }"
    end

    Invoice.find_by_sql(query.to_sql)
  end

  ##
  # Defined only, actually not used?
  # @param [Register] register
  def recalculate_contents_sum(register)
    register.invoices.live_receipts.where('commited_at IS NOT NULL').find_each do |invoice|
      if ['cash', 'ledger'].include?( invoice.payment_method )
        invoice.register_journal_delta = invoice.gross_total
      end

      invoice.save!
    end
  end

  def format_payment_method(string)
    case string
    when 'cash'
      'Barzahlung'
    when 'credit_card'
      'Kreditkarte'
    when 'transfer'
      'Überweisung'
    when 'ledger'
      'Kassabuch'
    end
  end

  private

  def format_currency(number)
    ('%.2f' % number).sub('.', ',')
  end
end
