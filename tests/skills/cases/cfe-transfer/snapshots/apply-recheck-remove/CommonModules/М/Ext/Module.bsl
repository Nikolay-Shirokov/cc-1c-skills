Процедура Д() Экспорт
	Подготовить();
	Завершить();
	Перенести();
КонецПроцедуры

Процедура П() Экспорт
	А();
	Б();
	В();
КонецПроцедуры

Procedure InsertRepeat() Export
    A();
    A();
EndProcedure
Procedure DeleteRepeat() Export
    A();
    A();
    A();
EndProcedure
Procedure NoOp() Export
    A();
EndProcedure
Procedure OptionalRepeat() Export
    A();
    A();
    B();
    C();
EndProcedure

Procedure DeleteComment() Export
    Start();
    EndStep();
    NewCode();
    // old comment
EndProcedure

Procedure EmptyAround() Export
EndProcedure
