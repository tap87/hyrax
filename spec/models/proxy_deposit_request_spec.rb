describe ProxyDepositRequest, type: :model do
  let(:sender) { create(:user) }
  let(:receiver) { create(:user) }
  let(:receiver2) { create(:user) }
  let(:work) do
    GenericWork.create(title: ["Test work"]) do |w|
      w.apply_depositor_metadata(sender.user_key)
    end
  end

  subject do
    described_class.new(work_id: work.id, sending_user: sender,
                        receiving_user: receiver, sender_comment: "please take this")
  end

  its(:status) { is_expected.to eq described_class::PENDING }
  it { is_expected.to be_pending }
  its(:fulfillment_date) { is_expected.to be_nil }
  its(:sender_comment) { is_expected.to eq 'please take this' }

  it { is_expected.to delegate_method(:to_s).to(:solr_doc) }

  context '#status' do
    it 'is protected by enum enforcement' do
      expect { described_class.new(status: 'not_valid') }.to raise_error(ArgumentError)
    end

    # Because the Rails documentation says "Declare an enum attribute where the values map to integers in the database, but can be queried by name." but appears to not be the case.
    it 'is persisted as a string' do
      subject.cancel!
      values = described_class.connection.execute("SELECT * FROM #{described_class.quoted_table_name}")
      expect(values.first.fetch('status')).to eq(described_class::CANCELED)
    end
  end

  context "After approval" do
    before do
      subject.transfer!
    end

    its(:status) { is_expected.to eq described_class::ACCEPTED }
    its(:fulfillment_date) { is_expected.not_to be_nil }
    its(:deleted_work?) { is_expected.to be false }

    describe "and the work is deleted" do
      before do
        work.destroy
      end

      its(:to_s) { is_expected.to eq 'work not found' }
      its(:deleted_work?) { is_expected.to be true }
    end

    describe "and the work transfer is canceled" do
      before do
        subject.cancel!
      end

      its(:status) { is_expected.to eq described_class::CANCELED }
      its(:fulfillment_date) { is_expected.not_to be_nil }
      its(:canceled?) { is_expected.to be true }
    end
  end

  context "After rejection" do
    before do
      subject.reject!('a comment')
    end

    its(:status) { is_expected.to eq described_class::REJECTED }
    its(:fulfillment_date) { is_expected.not_to be_nil }
    its(:receiver_comment) { is_expected.to eq 'a comment' }
  end

  context "After cancel" do
    before do
      subject.cancel!
    end

    its(:status) { is_expected.to eq described_class::CANCELED }
    its(:fulfillment_date) { is_expected.not_to be_nil }
  end

  describe 'transfer' do
    context 'when the transfer_to user is not found' do
      it 'raises an error' do
        subject.transfer_to = 'dave'
        expect(subject).not_to be_valid
        expect(subject.errors[:transfer_to]).to eq(['must be an existing user'])
      end
    end

    context 'when the transfer_to user is found' do
      it 'creates a transfer_request' do
        subject.transfer_to = receiver.user_key
        subject.save!
        proxy_request = receiver.proxy_deposit_requests.first
        expect(proxy_request.work_id).to eq(work.id)
        expect(proxy_request.sending_user).to eq(sender)
      end
    end

    context 'when the receiving user is the sending user' do
      it 'raises an error' do
        subject.transfer_to = sender.user_key
        expect(subject).not_to be_valid
        expect(subject.errors[:sending_user]).to eq(['must specify another user to receive the work'])
      end
    end

    context 'when the work is already being transferred' do
      let(:subject2) { described_class.new(work_id: work.id, sending_user: sender, receiving_user: receiver2, sender_comment: 'please take this') }

      it 'raises an error' do
        subject.save!
        expect(subject2).not_to be_valid
        expect(subject2.errors[:open_transfer]).to eq(['must close open transfer on the work before creating a new one'])
      end

      context 'when the first transfer is closed' do
        before do
          subject.status = described_class::ACCEPTED
        end

        it 'does not raise an error' do
          subject.save!
          expect(subject2).to be_valid
        end
      end
    end
  end
end
