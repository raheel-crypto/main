public with sharing class UserSelector {

    public static User fetchCurrentUser(Id userId) {
        try {
            return [SELECT Pipe_Gen_Annual_Target__c FROM User WHERE Id = :userId LIMIT 1];
        } catch (Exception e) {
            return null;
        }
    }

    public static List<User> fetchDirectReports(Id managerId) {
        return [
            SELECT Id, Name
            FROM   User
            WHERE  ManagerId = :managerId
              AND  IsActive   = true
            ORDER BY Name
        ];
    }
}
