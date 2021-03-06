/*
    Copyright (c) 2014, Salesforce.com Foundation
    All rights reserved.
    
    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:
    
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of the Salesforce.com Foundation nor the names of
      its contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT 
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS 
    FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE 
    COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, 
    INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, 
    BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; 
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER 
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT 
    LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN 
    ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE 
    POSSIBILITY OF SUCH DAMAGE.
*/
@isTest
public with sharing class ERR_Handler_TEST {

    // if you only want to run one test in this class, fill in its name here.
    // if you want to run all tests, then use '*'
    private static string strTestOnly = '*';
    
    private static Id chatterGroupId;
    
    private static void setupWithChatterNotifications() {
    	UTIL_CustomSettingsFacade.getContactsSettingsForTests(new npe01__Contacts_and_Orgs_Settings__c(
            npe01__Account_Processor__c = CAO_Constants.HH_ACCOUNT_PROCESSOR));
    	UTIL_CustomSettingsFacade.getHouseholdsSettingsForTests(new npo02__Households_Settings__c (
            npo02__Household_Rules__c = HH_Households.ALL_PROCESSOR, npo02__Enable_Opp_Rollup_Triggers__c = true));
    	
    	if(Schema.SObjectType.User.isFeedEnabled()) {
	    	SObject chatterGroup = (SObject)System.Type.forName('CollaborationGroup').newInstance();
	    	chatterGroup.put('Name', 'ChatterTestGroup');
	    	chatterGroup.put('CollaborationType', 'Private');
	    	insert chatterGroup;
	    	chatterGroupId = chatterGroup.Id;
	    	UTIL_CustomSettingsFacade.getErrorSettingsForTests(new Error_Settings__c(Error_Notifications_On__c = true, 
	    	  Error_Notifications_To__c = chatterGroup.Id, Store_Errors_On__c = true));
    	} else {
    		UTIL_CustomSettingsFacade.getErrorSettingsForTests(new Error_Settings__c(Error_Notifications_On__c = true, 
    		  Error_Notifications_To__c = null, Store_Errors_On__c = true));
    	}
    }
    
    private static void setupWithEmailNotifications() {
        UTIL_CustomSettingsFacade.getContactsSettingsForTests(new npe01__Contacts_and_Orgs_Settings__c(
            npe01__Account_Processor__c = CAO_Constants.HH_ACCOUNT_PROCESSOR));
        UTIL_CustomSettingsFacade.getHouseholdsSettingsForTests(new npo02__Households_Settings__c (
            npo02__Household_Rules__c = HH_Households.ALL_PROCESSOR, npo02__Enable_Opp_Rollup_Triggers__c = true));
        
        User user = UTIL_UnitTestData_TEST.CreateNewUserForTests(System.now().getTime() + '@testerson.com');
        UTIL_CustomSettingsFacade.getErrorSettingsForTests(new Error_Settings__c(Error_Notifications_On__c = true, 
            Error_Notifications_To__c = user.Id, Store_Errors_On__c = true));
    }
    
    /*** We need to use Database.insert because otherwise the code does not go passed the contacts insert operation
         in the test itself. 
         An error record gets inserted just because the name field for accounts was not retrieved. This happens in 
         the second pass of the Database.insert ***/
    public testmethod static void errorsStoredInDbTdtmCustomConfigPostToChatter() {
    	if (strTestOnly != '*' && strTestOnly != 'errorsStoredInDbTdtmCustomConfigPostToChatter') return;
    	
    	setupWithChatterNotifications();
    	
    	insert new Trigger_Handler__c(Active__c = true, Asynchronous__c = false, 
              Class__c = 'ERR_ParentAccountUpdater_TEST', Load_Order__c = 1, Object__c = 'Contact', 
              Trigger_Action__c = 'BeforeInsert;');
    	            
    	//Create account
    	Account acc1 = new Account(Name='test1');
    	Account acc2 = new Account(Name='test2');
    	Account acc3 = new Account(Name='test3');
        insert new Account[] {acc1, acc2, acc3};
        
        //Create contact
        Contact contact1 = new Contact(FirstName = 'test', LastName = 'testerson1', AccountId = acc1.Id, Title = 'VP1');
        Contact contact2 = new Contact(FirstName = 'test', LastName = 'testerson2', AccountId = acc2.Id, Title = 'VP2');
        Contact contact3 = new Contact(FirstName = 'test', LastName = 'testerson3', AccountId = acc3.Id, Title = 'VP3');

        //Delete the account to get ERR_ParentAccountUpdater_TEST code to throw an exception
        delete acc2;
        
        Test.startTest();
	    List<Contact> contacts = new Contact[]{contact1, contact2, contact3};
	    LIST<database.SaveResult> results = Database.insert(contacts, false);
        Test.stopTest();
        
        //Database.insert will roll everything back if there is an error, and then run again only with the records that
        //don't produce exceptions
        System.assertEquals(true, results[0].isSuccess());  
        System.assertEquals(false, results[1].isSuccess()); 
        System.assertEquals(true, results[2].isSuccess()); 

        //Verify 2 contacts were properly inserted
        list<Contact> insertedContacts = [select Id from Contact where Id in :contacts];
        System.assertEquals(2, insertedContacts.size()); 
        
        //Verify error record was created - because the name field for accounts was not retrieved when we try to access
        //it in line 40 of ERR_ParentAccountUpdater_TEST (in the second pass of the Database.insert operation)
        List<Error__c> errors = [select Id, Full_Message__c, Stack_Trace__c, Posted_in_Chatter__c from Error__c];
        System.assertEquals(1, errors.size());
        System.debug('****Errors: ' + JSON.serializePretty(errors));
        
        //Verify error was posted to chatter group
        if(Schema.SObjectType.User.isFeedEnabled()) {
	        List<SObject> chatterPosts = Database.query('select Title from FeedItem where ParentId = :chatterGroupId');
	        System.assertEquals(1, chatterPosts.size());
	        System.assertEquals('NPSP Error', chatterPosts[0].get('Title'));
	        for(Error__c error : errors) {
	        	System.assertEquals(true, error.Posted_in_Chatter__c);
	        }
        }
    }
    
    /*** We need to use Database.insert because otherwise the code does not go passed the contacts insert operation
         in the test itself. 
         An error record gets inserted just because the name field for accounts was not retrieved. This happens in 
         the second pass of the Database.insert ***/
    public testmethod static void errorsStoredInDbTdtmCustomConfigEmailErrors() {
        if (strTestOnly != '*' && strTestOnly != 'errorsStoredInDbTdtmCustomConfigEmailErrors') return;
        
        setupWithEmailNotifications();
        
        insert new Trigger_Handler__c(Active__c = true, Asynchronous__c = false, 
              Class__c = 'ERR_ParentAccountUpdater_TEST', Load_Order__c = 1, Object__c = 'Contact', 
              Trigger_Action__c = 'BeforeInsert;');
                    
        //Create account
        Account acc1 = new Account(Name='test1');
        Account acc2 = new Account(Name='test2');
        Account acc3 = new Account(Name='test3');
        insert new Account[] {acc1, acc2, acc3};
        
        //Create contact
        Contact contact1 = new Contact(FirstName = 'test', LastName = 'testerson1', AccountId = acc1.Id, Title = 'VP1');
        Contact contact2 = new Contact(FirstName = 'test', LastName = 'testerson2', AccountId = acc2.Id, Title = 'VP2');
        Contact contact3 = new Contact(FirstName = 'test', LastName = 'testerson3', AccountId = acc3.Id, Title = 'VP3');

        //Delete the account to get ERR_ParentAccountUpdater_TEST code to throw an exception
        delete acc2;
        
        Test.startTest();
        List<Contact> contacts = new Contact[]{contact1, contact2, contact3};
        LIST<database.SaveResult> results = Database.insert(contacts, false);
        Test.stopTest();
        
        //Database.insert will roll everything back if there is an error, and then run again only with the records that
        //don't produce exceptions
        System.assertEquals(true, results[0].isSuccess());  
        System.assertEquals(false, results[1].isSuccess()); 
        System.assertEquals(true, results[2].isSuccess()); 

        //Verify 2 contacts were properly inserted
        list<Contact> insertedContacts = [select Id from Contact where Id in :contacts];
        System.assertEquals(2, insertedContacts.size()); 
        
        //Verify error record was created - because the name field for accounts was not retrieved when we try to access
        //it in line 40 of ERR_ParentAccountUpdater_TEST (in the second pass of the Database.insert operation)
        List<Error__c> errors = [select Id, Full_Message__c, Stack_Trace__c, Email_Sent__c from Error__c];
        System.assertEquals(1, errors.size());
        
        //Verify error was emailed
        for(Error__c error : errors) {
            System.assertEquals(true, error.Email_Sent__c);
        }
    }
    
    /** To prove that there are different types of null pointer exceptions. In this case the account
    name is always available. The error does not get stored because the second time that Database.insert 
    runs there are no errors. **/
    public testmethod static void errorsStoredInDbTdtmCustomConfig2() {
        if (strTestOnly != '*' && strTestOnly != 'errorsStoredInDbTdtmCustomConfig') return;
        
        setupWithChatterNotifications();
        
        insert new Trigger_Handler__c(Active__c = true, Asynchronous__c = false, 
              Class__c = 'ERR_ParentAccountUpdater2_TEST', Load_Order__c = 1, Object__c = 'Contact', 
              Trigger_Action__c = 'BeforeInsert;');
                    
        //Create account
        Account acc1 = new Account(Name='test1');
        Account acc2 = new Account(Name='test2');
        Account acc3 = new Account(Name='test3');
        insert new Account[] {acc1, acc2, acc3};
        
        //Create contact
        Contact contact1 = new Contact(FirstName = 'test', LastName = 'testerson1', AccountId = acc1.Id, Title = 'VP1');
        Contact contact2 = new Contact(FirstName = 'test', LastName = 'testerson2', AccountId = acc2.Id, Title = 'VP2');
        Contact contact3 = new Contact(FirstName = 'test', LastName = 'testerson3', AccountId = acc3.Id, Title = 'VP3');

        //Delete the account to get ERR_ParentAccountUpdater_TEST code to throw an exception
        delete acc2;
        
        Test.startTest();
        List<Contact> contacts = new Contact[]{contact1, contact2, contact3};
        LIST<database.SaveResult> results = Database.insert(contacts, false);
        Test.stopTest();
        
        //Database.insert will roll everything back if there is an error, and then run again only with the records that
        //don't produce exceptions
        System.assertEquals(true, results[0].isSuccess());  
        System.assertEquals(false, results[1].isSuccess()); 
        System.assertEquals(true, results[2].isSuccess());

        //Verify 2 contacts were properly inserted
        list<Contact> insertedContacts = [select Id from Contact where Id in :contacts];
        System.assertEquals(2, insertedContacts.size()); 
        
        //Verify no error record was created
        List<Error__c> errors = [select Id, Full_Message__c, Stack_Trace__c from Error__c];
        System.assertEquals(0, errors.size()); 
    }
    
    /** Test using the default configuration of classes that implement TDTM_Runnable **/
    public testmethod static void errorStoredInDbTdtmStandardConfig() {
    	if (strTestOnly != '*' && strTestOnly != 'errorStoredInDbTdtmStandardConfig') return;
    
        setupWithChatterNotifications();
        
        UTIL_CustomSettingsFacade.getAffiliationsSettingsForTests(
            new npe5__Affiliations_Settings__c(npe5__Automatic_Affiliation_Creation_Turned_On__c = true));
                    
        //Create account
        Account acc1 = new Account(Name='test1');
        Account acc2 = new Account(Name='test2');
        Account acc3 = new Account(Name='test3');
        insert new Account[] {acc1, acc2, acc3};
        
        //Create contact
        Contact contact1 = new Contact(FirstName = 'test', LastName = 'testerson1', AccountId = acc1.Id, Title = 'VP1');
        Contact contact2 = new Contact(FirstName = 'test', LastName = 'testerson2', AccountId = acc2.Id, Title = 'VP2');
        Contact contact3 = new Contact(FirstName = 'test', LastName = 'testerson3', AccountId = acc3.Id, Title = 'VP3');

        //Delete the account to get the affiliations code to throw an exception
        delete acc2;
        
        Test.startTest();
        List<Contact> contacts = new Contact[]{contact1, contact2, contact3};
        LIST<database.SaveResult> results = Database.insert(contacts, false);
        Test.stopTest();
        
        //Database.insert will roll everything back if there is an error, and then run again only with the records that
        //don't produce exceptions
        System.assertEquals(true, results[0].isSuccess());  
        System.assertEquals(false, results[1].isSuccess()); 
        System.assertEquals(true, results[2].isSuccess()); 

        //Verify 2 contacts were properly inserted
        list<Contact> insertedContacts = [select Id from Contact where Id in :contacts];
        System.assertEquals(2, insertedContacts.size()); 
        
        //Verify error record was created -> Nope. Since we are using Database insert the operation
        //gets rolled back and then run again only with records that succeed. No error is saved.
        //**Note that we have not created a Trigger_Handler__c record with the test class that would throw an exception**
        List<Error__c> errors = [select Id, Full_Message__c, Stack_Trace__c from Error__c];
        System.debug('****ERROR: ' + JSON.serializePretty(errors));
        System.assertEquals(0, errors.size());                                    
    }
    
    /** This is the same test called testErrorRecordCreation in the REL_Relationships_TEST class, but
        using simple insert instead of Database.insert ***/
    static testMethod void errorStoredInDatabaseFromInsert() {
        if (strTestOnly != '*' && strTestOnly != 'errorStoredInDatabaseFromInsert') return;
        
        setupWithChatterNotifications();
        
        Contact contact1 = new Contact(FirstName = 'test', LastName = 'testerson1', Title = 'VP1');
        insert contact1;
                
        npe4__Relationship__c[] relationships = new npe4__Relationship__c[]{
            new npe4__Relationship__c(npe4__contact__c = contact1.id, npe4__Type__c='TestLookupType') };
        
        insert relationships;
        //assert an error record was created - Required fields are missing: [npe4__Contact__c]
        system.assertEquals(1, [select count() from Error__c]);
        
        //update relationship - this will create the missing npe4__Contact__c field
        relationships[0].npe4__RelatedContact__c = contact1.id;
        Database.SaveResult[] updateResults = Database.update(relationships, false);
        
        //process error
        ERR_Handler errorHandler = new ERR_Handler();
        errorHandler.processUpdateResults(updateResults, (List<SObject>)relationships, ERR_Handler.Context.REL);

        //assert no additional error was created on update
        system.assertEquals(1, [select count() from Error__c]);
    }
    
    /*** Testing that DML that occurs before an exception is thrown and caught does not get automatically rolled back ***/
    static testMethod void controllerWithoutManualRollback() {
        if (strTestOnly != '*' && strTestOnly != 'controllerWithoutManualRollback') return;
        
        setupWithChatterNotifications();
        
        ERR_Handler_CTRL_TEST controller = new ERR_Handler_CTRL_TEST();
        
        Test.startTest();
        controller.withoutManualRollback();
        Test.stopTest();
        
        //assert contact record creation was not automatically rolled back
         system.assertEquals(1, [select count() from Contact]);
        
        //assert relationship record was stored (but the additional relationship was not created)
         system.assertEquals(1, [select count() from npe4__Relationship__c]);
         
        //assert an error record was created - Required fields are missing: [npe4__Contact__c]
        system.assertEquals(1, [select count() from Error__c]);  
    }
    
    /*** Testing that DML changes are properly rolled back in a controller that adheres to our error-handling design, and
         that the error is properly stored. ***/
    static testMethod void controllerWithManualRollback() {
        if (strTestOnly != '*' && strTestOnly != 'controllerWithManualRollback') return;
        
        setupWithChatterNotifications();
        
        ERR_Handler_CTRL_TEST controller = new ERR_Handler_CTRL_TEST();
        
        Test.startTest();
        controller.withManualRollback();
        Test.stopTest();
        
        //assert contact record creation was rolled back
        system.assertEquals(0, [select count() from Contact]);
        
        //assert relationship record was not stored
        system.assertEquals(0, [select count() from npe4__Relationship__c]);
         
        //assert an error record was created - Required fields are missing: [npe4__Contact__c]
        system.assertEquals(1, [select count() from Error__c]);    
    }

    /** Test that an inactive user won't receive email as the primary error user **/
    static testMethod void testInactiveUserEmailBehavior() {

        if (strTestOnly != '*' && strTestOnly != 'testInactiveUserEmailBehavior') return;

        String un = System.now().getTime() + '@testerson.com';
        Profile p = [SELECT Id FROM Profile WHERE Name='Standard User'];
        UserRole r = [SELECT Id FROM UserRole WHERE Name='COO'];
        User u; 
        System.runAs ( new User(Id = UserInfo.getUserId()) ) { 
            u = new User(alias = 'jsmith', email='jsmith@acme.com', 
                emailencodingkey='UTF-8', lastname='Smith', 
                languagelocalekey='en_US', 
                localesidkey='en_US', profileid = p.Id, userroleid = r.Id,
                timezonesidkey='America/Los_Angeles', 
                username=un, isActive = false);
            insert u;}

        UTIL_CustomSettingsFacade.getErrorSettingsForTests(new Error_Settings__c(Error_Notifications_On__c = true, 
            Error_Notifications_To__c = u.Id, Store_Errors_On__c = true));
 
        insert new Trigger_Handler__c(Active__c = true, Asynchronous__c = false, 
              Class__c = 'ERR_ParentAccountUpdater_TEST', Load_Order__c = 1, Object__c = 'Contact', 
              Trigger_Action__c = 'BeforeInsert;');

        //Create account
        Account acc1 = new Account(Name='test1');
        Account acc2 = new Account(Name='test2');
        Account acc3 = new Account(Name='test3');
        insert new Account[] {acc1, acc2, acc3};

        //Create contact
        Contact contact1 = new Contact(FirstName = 'test', LastName = 'testerson1', AccountId = acc1.Id, Title = 'VP1');
        Contact contact2 = new Contact(FirstName = 'test', LastName = 'testerson2', AccountId = acc2.Id, Title = 'VP2');
        Contact contact3 = new Contact(FirstName = 'test', LastName = 'testerson3', AccountId = acc3.Id, Title = 'VP3');

        //Delete the account to get ERR_ParentAccountUpdater_TEST code to throw an exception
        delete acc2;

        Test.startTest();
        List<Contact> contacts = new Contact[]{contact1, contact2, contact3};
        LIST<database.SaveResult> results = Database.insert(contacts, false);
        Test.stopTest();

        //Database.insert will roll everything back if there is an error, and then run again only with the records that
        //don't produce exceptions
        System.assertEquals(true, results[0].isSuccess());  
        System.assertEquals(false, results[1].isSuccess()); 
        System.assertEquals(true, results[2].isSuccess()); 

        //Verify 2 contacts were properly inserted
        list<Contact> insertedContacts = [select Id from Contact where Id in :contacts];
        System.assertEquals(2, insertedContacts.size()); 

        //Verify error record was created - because the name field for accounts was not retrieved when we try to access
        //it in line 40 of ERR_ParentAccountUpdater_TEST (in the second pass of the Database.insert operation)
        List<Error__c> errors = [select Id, Full_Message__c, Stack_Trace__c, Email_Sent__c from Error__c];
        System.assertEquals(1, errors.size());

        //Verify error was NOT emailed
        for(Error__c error : errors) {
            System.assertEquals(false, error.Email_Sent__c);
        }
    }
}