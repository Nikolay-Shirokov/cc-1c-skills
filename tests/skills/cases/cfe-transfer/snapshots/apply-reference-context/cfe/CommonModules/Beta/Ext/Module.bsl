Procedure Ext_Message() Export
    Value = 2;
EndProcedure
Procedure Ext_Caller() Export
    Alpha.Ext_Message();
    Ext_Message();
    Path = "inbox/Ext_receipt.xml"; // Ext_Message stays
    If Id = "Ext_Message" Then
        Value = "Ext_Message" + Suffix;
    EndIf;
    N = New CallbackDescription(
        "Ext_Message", Beta, New Structure("x", F(1, 2)),
        "Ext_Message", Alpha);
EndProcedure

&ChangeAndValidate("Original")
Procedure Ext_Original()
    Start();
    #Delete
    Value = "ABC";
    #EndDelete
    #Insert
    NewValue = 1;
    #EndInsert
    Finish();
EndProcedure
