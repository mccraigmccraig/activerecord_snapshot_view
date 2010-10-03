require File.expand_path(File.dirname(__FILE__) + '/spec_helper')

describe "ActiverecordSnapshotView" do
  describe "prepare_to_migrate" do
    describe "class from symbol" do
      it "should return a class given a symbol" do
        ActiveRecord::SnapshotView.class_from_symbol(:object).should == Object
        ActiveRecord::SnapshotView.class_from_symbol(:"active_record/snapshot_view").should == ActiveRecord::SnapshotView
      end
    end
  end
end
