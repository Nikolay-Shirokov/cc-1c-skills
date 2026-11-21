&ИзменениеИКонтроль("Д")
Процедура Тест_Д()
	Подготовить();
	#Удаление
	Перенести();
	#КонецУдаления
	Завершить();
	#Вставка
	Перенести();
	#КонецВставки
КонецПроцедуры

&ИзменениеИКонтроль("П")
Процедура Тест_П()
	А();
	Б();
	#Удаление
	А();
	#КонецУдаления
	В();
КонецПроцедуры

&ChangeAndValidate("InsertRepeat")
Procedure Test_InsertRepeat()
#Insert
    A();
#EndInsert
    A();
EndProcedure
&ChangeAndValidate("DeleteRepeat")
Procedure Test_DeleteRepeat()
    A();
#Delete
    A();
#EndDelete
    A();
    A();
EndProcedure
&ChangeAndValidate("NoOp")
Procedure Test_NoOp()
#Delete
    A();
#EndDelete
#Insert
    A();
#EndInsert
EndProcedure
&ChangeAndValidate("OptionalRepeat")
Procedure Test_OptionalRepeat()
    A();
#Insert
    A();
#EndInsert
    B();
#Insert // Временно: debug
    A();
#EndInsert
    C();
EndProcedure

&ChangeAndValidate("DeleteComment")
Procedure Test_DeleteComment()
    Start();
#Delete
    // old comment
#EndDelete
    EndStep();
#Insert
    NewCode();
#EndInsert
    // old comment
EndProcedure
