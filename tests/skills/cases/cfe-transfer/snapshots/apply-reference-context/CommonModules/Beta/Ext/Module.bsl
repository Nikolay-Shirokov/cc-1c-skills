Procedure Original() Export
    Start();
//    Value = "ABC";
    NewValue = 1;
    Finish();
EndProcedure

#Region ПрограммныйИнтерфейс

Procedure Message() Export
    Value = 2;
EndProcedure

Procedure Caller() Export
    Alpha.Ext_Message();
    Message();
    Path = "inbox/Ext_receipt.xml"; // Ext_Message stays
    If Id = "Ext_Message" Then
        Value = "Ext_Message" + Suffix;
    EndIf;
    N = New CallbackDescription(
        "Message", Beta, New Structure("x", F(1, 2)),
        "Ext_Message", Alpha);
EndProcedure

#EndRegion
