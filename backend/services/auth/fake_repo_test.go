package auth

import (
	"context"
	"errors"
	"time"
)

// fakeRepo is an in-memory authRepo double.
type fakeRepo struct {
	users  map[string]User
	nextID int64
	failOn map[string]error
}

func newFakeRepo() *fakeRepo {
	return &fakeRepo{users: map[string]User{}, nextID: 1, failOn: map[string]error{}}
}

var errFakeUserNotFound = errors.New("auth: fake repo: user not found")

func (f *fakeRepo) UpsertUser(ctx context.Context, address string) (User, error) {
	if err := f.failOn["UpsertUser"]; err != nil {
		return User{}, err
	}
	if u, ok := f.users[address]; ok {
		return u, nil
	}
	u := User{ID: f.nextID, StellarAddress: address, CreatedAt: time.Now()}
	f.nextID++
	f.users[address] = u
	return u, nil
}

func (f *fakeRepo) GetUserByAddress(ctx context.Context, address string) (User, error) {
	if err := f.failOn["GetUserByAddress"]; err != nil {
		return User{}, err
	}
	u, ok := f.users[address]
	if !ok {
		return User{}, errFakeUserNotFound
	}
	return u, nil
}
