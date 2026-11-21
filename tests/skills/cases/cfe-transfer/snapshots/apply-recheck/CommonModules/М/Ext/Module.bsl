#Область СлужебныеПроцедурыИФункции

Процедура А() Экспорт
	Х = 1;
	// проверка прав
	ПроверитьПрава();
	Записать();
КонецПроцедуры

Процедура Б() Экспорт
	Начать();
	Начало();
//	Удалить1();
	Конец();
КонецПроцедуры

Процедура В() Экспорт
	Х = 1;
	Проверить();
	Записать();
	Тест_Сообщить();
КонецПроцедуры

Процедура Г() Экспорт
	А();
	Б();
//	А();
	В();
КонецПроцедуры

Функция Сумма(А, Б)
	Возврат А + Б;
КонецФункции

#КонецОбласти

Procedure InsertRepeat() Export
    A();
    A();
EndProcedure
Procedure DeleteRepeat() Export
    A();
//    A();
    A();
    A();
EndProcedure

#Если Сервер Тогда
#Region SameScope
Procedure BaseServer() Export
    Message("scope");
EndProcedure

Procedure SameScopeMethod() Export
    Message("scope");
EndProcedure

#EndRegion
#КонецЕсли

#If Client Then
#Region DifferentScope
Procedure BaseClient() Export
    Message("scope");
EndProcedure
#EndRegion
#EndIf

#If Server Then
Procedure OtherScopeMethod() Export
    Message("scope");
EndProcedure
#EndIf

#Область ПрограммныйИнтерфейс

Процедура Тест_Сообщить() Экспорт
	Сообщить("Готово");
КонецПроцедуры

#If Server Then
Procedure ServerOne() Export
    Message("scope");
EndProcedure

Procedure ServerTwo() Export
    Message("scope");
EndProcedure
#EndIf

#If Not (Server) And (Client Or ExternalConnection) Then
Procedure ElseIfScope() Export
    Message("scope");
EndProcedure
#EndIf

#If Not (Server) And Not (Client Or ExternalConnection) Then
Procedure ElseScope() Export
    Message("scope");
EndProcedure
#EndIf

#If Server Then
Procedure ServerTail() Export
    Message("scope");
EndProcedure
#EndIf

#If Server Then
#If Not ExternalConnection Then
Procedure NestedScope() Export
    Message("scope");
EndProcedure
#EndIf
#EndIf

#КонецОбласти
